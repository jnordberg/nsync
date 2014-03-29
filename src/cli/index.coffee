### nsync command line interface ###

chalk = require 'chalk'
fs = require 'fs'
listModules = require './list'
minimist = require 'minimist'
nsync = require './../'
path = require 'path'
{logger} = require './logger'
{readJSONSync, writeJSONSync, humanSize} = require './../utils'

defaults =
  destination: './'
  manifest: 'manifest.json'
  concurrency: 4
  destructive: false
  force: false
  pretend: false
  gitignore: true
  ignore: []

usage = "usage: nsync #{ chalk.bold '<transport>' } [options] #{ chalk.bold '<input directory>' }"

optionsUsage = """
  options:

    -c, --config <filename>     config file to use (default: ./nsync.json)
    -d, --destination <path>    path to write to on destination (default: ./)
    -f, --force                 force rebuild of destination manifest
    -m, --manifest <filename>   manifest filename to use (default: manifest.json)
        --no-manifest           dont use a manifest
    -C, --concurrency <num>     max number of concurrent operations (default: 4)
    -i, --ignore                file or pattern to ignore (repeatable)
        --no-gitignore          disable parsing of .gitignore files
    -X, --destructive           delete files and directories on destination
    -p, --pretend               don't actually do anything
    -S, --save [filename]       save current options to config file
    -v, --verbose               show debug information
    -q, --quiet                 only output critical errors
    -V, --version               output version and exit
    -h, --help                  show usage

"""

isTransport = (name) ->
  /^nsync\-/.test name

normalizeTransportName = (name) ->
  name.replace /^nsync\-/, ''

camel2dash = (string) ->
  string.replace /([A-Z])/g, (m) ->
    "-#{ m.toLowerCase() }"

dash2camel = (string) ->
  string.replace /(\-[a-z])/g, (m) ->
    m.toUpperCase().replace '-', ''

resolveTransport = (name) ->
  switch name[0]
    when '.'
      id = require.resolve path.join(process.cwd(), name)
    when '/'
      id = require.resolve name
    else
      try
        id = require.resolve "nsync-#{ name }"
      catch error
        if error.code is 'MODULE_NOT_FOUND'
          id = require.resolve name
        else
          throw error
  return id

resolveOptions = (argv, config, defaults) ->
  options = {}
  # argv > config > defaults
  for key of defaults
    options[key] = argv[key] ? argv[camel2dash key]
    options[key] ?= config[key]
    options[key] ?= defaults[key]
  return options

lpad = (str, length, padStr=' ') ->
  while str.length < length
    str = padStr + str
  return str

rpad = (str, length, padStr=' ') ->
  while str.length < length
    str = str + padStr
  return str

transportUsage = (transport) ->
  rv = "transport options:\n\n"
  pad = Object.keys transport.options
    .map camel2dash
    .reduce (prev, current) ->
      Math.max prev.length or prev, current.length

  for key, opt of transport.options
    rv += rpad "  --#{ camel2dash key }", pad + 6
    rv += "  #{ opt.description }"
    if opt.required or opt.default
      extra = []
      extra.push 'required' if opt.required
      extra.push "default: #{ opt.default }" if opt.default?
      rv += " (#{ extra.join ', ' })"
    rv += '\n'

  return rv

main = (argv, callback) ->

  nversion = process.version.substr(1).split('.').map (item) -> parseInt item
  if nversion[0] is 0 and nversion[1] < 10
    process.stderr.write "nsync requires node >=0.10 (you have: #{ nversion.join '.' })\n"
    process.exit 1

  argv = minimist argv.slice(2),
    alias:
      concurrency: 'C'
      config: 'c'
      destination: 'd'
      destructive: 'X'
      force: 'f'
      help: 'h'
      manifest: 'm'
      quiet: 'q'
      save: 'S'
      verbose: 'v'
      version: 'V'
      ignore: 'i'
    boolean: [
      'destructive', 'force', 'help', 'pretend'
      'quiet', 'verbose', 'version', 'gitignore'
    ]

  if argv.verbose
    if '-vv' in process.argv
      logger.transports.cli.level = 'silly'
    else
      logger.transports.cli.level = 'verbose'

  if argv.quiet
    logger.transports.cli.quiet = true

  transportName = argv._[0]
  sourceDirectory = argv._[1]

  if not transportName?
    availableTransports = listModules process.cwd()
      .filter isTransport
      .map normalizeTransportName
    availableTransports.push 'fs'

    process.stderr.write """
      #{ usage }

      available transports: #{ availableTransports.map (name) -> chalk.bold name  }

      #{ optionsUsage }

    """

    process.exit 1

  try
    if transportName is 'fs'
      transport = nsync.FsTransport
    else
      transport = require resolveTransport transportName
  catch error
    if error.code is 'MODULE_NOT_FOUND'
      logger.error "Transport #{ transportName } not found!"
    else
      logger.error "Transport #{ transportName }: #{ error.message }", error
    process.exit 1

  if not sourceDirectory? or argv.help
    out = if argv.help then process.stdout else process.stderr
    out.write """
      #{ usage.replace '<transport>', transportName }\n
      #{ transportUsage(transport) }
      #{ optionsUsage }\n
    """
    process.exit if argv.help then 0 else 1

  configPath = argv.config or './nsync.json'
  if fs.existsSync configPath
    try
      config = readJSONSync configPath
    catch error
      logger.error "Failed loading config file: #{ configPath }", error
      process.exit 1
  else
    config = {}
    if argv.config?
      logger.error "Could not find config file: #{ configPath }"
      process.exit 1

  options = resolveOptions argv, config, defaults
  logger.verbose 'options', options

  transportDefaults = {}
  for key, opt of transport.options
    transportDefaults[key] = if opt.default? then opt.default else null

  transportConfig = config[normalizeTransportName(transportName)] or {}
  transportOptions = resolveOptions argv, transportConfig, transportDefaults
  logger.verbose 'transport options', transportOptions

  for key of transportOptions
    if not transportOptions[key]? and transport.options[key].required
      logger.error "Transport #{ transportName } requires option '#{ key }' to be set"
      process.exit 1

  ignore = if Array.isArray options.ignore then options.ignore else [options.ignore]

  # parse .gitignore if found
  ignoreFile = path.join sourceDirectory, '.gitignore'
  if fs.existsSync ignoreFile
    fs.readFileSync ignoreFile
      .toString()
      .split '\n'
      .filter (v) -> v.length
      .forEach (v) -> ignore.push v

  source = new nsync.FsTransport {path: sourceDirectory}
  destination = new transport transportOptions

  nsyncOpts =
    logger: logger
    concurrency: options.concurrency
    destructive: options.destructive
    pretend: options.pretend
    destinationPath: options.destination
    manifest: options.manifest
    forceRebuild: options.force
    ignore: ignore

  logger.info ''
  logger.info "Synchronizing #{ sourceDirectory.bold } using transport #{ transportName.bold }\n"

  start = process.hrtime()
  nsync source, destination, nsyncOpts, (error, stats) ->
    if error?
      logger.error error.message, error if error?
    else
      delta = process.hrtime start
      deltaS = (delta[0] + (delta[1] / 1e9)).toFixed(2).replace(/\.00/, '')
      logger.info ''
      logger.info "Done! Transfered #{ chalk.bold humanSize stats.bytesTransfered } in #{ chalk.bold deltaS + 's' }"
      logger.info ''
    callback? error, stats


module.exports = main