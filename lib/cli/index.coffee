### nsync command line interface ###

chalk = require 'chalk'
fs = require 'fs'
listModules = require './list'
minimist = require 'minimist'
nsync = require './../'
path = require 'path'
{CliStream} = require './logger'
bunyan = require 'bunyan'
{readJSONSync, writeJSONSync} = require './../utils'

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
    -q, --quiet                 only output critical errors
    -V, --version               output version and exit
        --debug                 show debug information
        --json                  output json log stream
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

createLogger = (options, output=process.stdout) ->
  type = 'stream'
  level = 'error'
  stream = output

  if not options.json
    type = 'raw'
    stream = new CliStream options.debug
    stream.pipe output

  if not options.quiet
    level = if options.debug then 'trace' else 'info'

  logger = bunyan.createLogger
    name: 'nsync'
    src: options.debug
    streams: [{level, type, stream}]

  return logger

main = (argv) ->

  nversion = process.version.substr(1).split('.').map (item) -> parseInt item
  if nversion[0] is 0 and nversion[1] < 10
    process.stderr.write "nsync requires node >=0.10 (you have: #{ nversion.join '.' })\n"
    process.exit 1

  exit = (code) ->
    # give the log streams a chance to flush before exiting
    setImmediate -> process.exit code

  argv = minimist argv.slice(2),
    alias:
      concurrency: 'C'
      config: 'c'
      destination: 'd'
      destructive: 'X'
      force: 'f'
      help: 'h'
      ignore: 'i'
      manifest: 'm'
      quiet: 'q'
      save: 'S'
      version: 'V'
    boolean: [
      'debug', 'destructive', 'force', 'gitignore'
      'help', 'pretend', 'quiet', 'version'
    ]

  logger = createLogger argv

  if argv.debug
    try
      smc = require 'source-map-support'
      smc.install()
    catch error
      logger.warn error, 'npm install source-map-support to get correct line numbers'

  transportName = argv._[0]
  sourceDirectory = argv._[1]

  if not transportName? or (not transportName? and argv.help)
    availableTransports = listModules process.cwd()
      .filter isTransport
      .map normalizeTransportName
      .map (name) -> chalk.bold name
      .join ' '

    out = if argv.help then process.stdout else process.stderr
    out.write """
      #{ usage }\n
      available transports: #{ chalk.bold 'fs' } #{ availableTransports  }\n
      #{ optionsUsage }\n
    """
    exit if argv.help then 0 else 1
    return

  try
    if transportName is 'fs'
      transport = nsync.FsTransport
    else
      transport = require resolveTransport transportName
  catch error
    if error.code is 'MODULE_NOT_FOUND'
      logger.error "Transport #{ transportName } not found!"
    else
      logger.error error, "Could not load transport '#{ transportName }'"
    exit 1
    return

  if not sourceDirectory? or argv.help
    out = if argv.help then process.stdout else process.stderr
    out.write """
      #{ usage.replace '<transport>', transportName }\n
      #{ transportUsage(transport) }
      #{ optionsUsage }\n
    """
    exit if argv.help then 0 else 1
    return

  configPath = argv.config or './nsync.json'
  if fs.existsSync configPath
    try
      config = readJSONSync configPath
    catch error
      logger.error error, "Failed loading config file: #{ configPath }"
      exit 1
      return
  else
    config = {}
    if argv.config?
      logger.error "Could not find config file: #{ configPath }"
      exit 1
      return

  options = resolveOptions argv, config, defaults
  logger.debug {options}, 'resolved options'

  transportDefaults = {}
  for key, opt of transport.options
    transportDefaults[key] = if opt.default? then opt.default else null

  transportConfig = config[normalizeTransportName(transportName)] or {}
  transportOptions = resolveOptions argv, transportConfig, transportDefaults
  logger.debug {options: transportOptions}, 'transport options'

  for key of transportOptions
    if not transportOptions[key]? and transport.options[key].required
      logger.error "Transport #{ transportName } requires option '#{ key }' to be set"
      exit 1
      return

  ignore = if Array.isArray options.ignore then options.ignore else [options.ignore]

  if options.gitignore
    ignore.push '.git'
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

  logger.info "Synchronizing %s using transport %s", sourceDirectory, transportName

  nsync source, destination, nsyncOpts, (error) ->
    exit if error? then 1 else 0

module.exports = main
