chalk = require 'chalk'
fs = require 'fs'
path = require 'path'
bunyan = require 'bunyan'

nsync = require './../'
listModules = require './list'
{CliStream} = require './logger'
{readJSONSync, writeJSONSync} = require './../utils'
packageInfo = require(path.join(__dirname, '../../package.json'))
ArgumentParser = require('argparse').ArgumentParser

camel2dash = (string) ->
  string.replace /([A-Z])/g, (m) ->
    "-#{ m.toLowerCase() }"

isTransport = (name) ->
  /^nsync\-/.test name

normalizeTransportName = (name) ->
  name.replace /^nsync\-/, ''

requireTransport = (name) ->
  try
    if name is 'fs'
      return nsync.FsTransport
    try
      return require.resolve "nsync-#{name}"
    catch error
      if error.code is 'MODULE_NOT_FOUND'
        return require.resolve name
      else
        throw error
  catch error
    if error.code is 'MODULE_NOT_FOUND'
      logger.error "Transport #{name} not found!"
    else
      logger.error error, "Could not load transport '#{name}'"
    exit 1

resolveOptions = (args, config, defaults) ->
  options = {}
  # args > config > defaults
  for key of defaults
    options[key] = args[key] ? args[camel2dash key]
    options[key] ?= config[key]
    options[key] ?= defaults[key]
  return options

rpad = (str, length, padStr=' ') ->
  while str.length < length
    str = str + padStr
  return str

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

main = ->
  exit = (code) ->
    # give the log streams a chance to flush before exiting
    setImmediate -> process.exit code

  availableTransports = listModules process.cwd()
    .filter isTransport
    .map normalizeTransportName
  availableTransports.push 'fs'

  transports = {}
  for name in availableTransports
    transports[name] = requireTransport name

  argparser = new ArgumentParser(
    version: packageInfo.version
    addHelp: true
    description: packageInfo.description
  )

  argparser.addArgument(
    ['--config', '-c']
    type: 'string'
    defaultValue: './nsync.json'
    help: 'Config file to use'
    metavar: 'FILENAME'
  )
  argparser.addArgument(
    ['--destination', '-d']
    type: 'string'
    defaultValue: './'
    help: 'Path to write to on destination'
    metavar: 'PATH'
  )
  argparser.addArgument(
    ['--force', '-f']
    action: 'storeTrue'
    defaultValue: false
    help: 'Force rebuild of destination manifest'
  )

  manifestGroup = argparser.addMutuallyExclusiveGroup()
  manifestGroup.addArgument(
    ['--manifest', '-m']
    type: 'string'
    defaultValue: 'manifest.json'
    help: 'manifest filename to use'
    metavar: 'FILENAME'
  )
  manifestGroup.addArgument(
    ['--no-manifest']
    type: 'string'
    action: 'storeFalse'
    dest: 'manifest'
    help: 'dont use a manifest'
  )

  argparser.addArgument(
    ['--concurrency', '-C']
    type: 'int'
    defaultValue: 4
    help: 'max number of concurrent operations'
    metavar: 'NUM'
  )
  argparser.addArgument(
    ['--ignore', '-i']
    type: 'string'
    action: 'append'
    help: 'file or pattern to ignore (repeatable)'
  )
  argparser.addArgument(
    ['--no-gitignore']
    action: 'storeFalse'
    defaultValue: true
    dest: 'gitignore'
    help: 'disable parsing of .gitignore files and ignoring of .git directories'
  )
  argparser.addArgument(
    ['--destructive', '-X']
    action: 'storeTrue'
    defaultValue: false
    help: 'delete files and directories on destination'
  )
  argparser.addArgument(
    ['--pretend', '-p']
    action: 'storeTrue'
    defaultValue: false
    help: 'don\'t actually do anything'
  )
  argparser.addArgument(
    ['--save', '-S']
    type: 'string'
    help: 'save current options to FILENAME'
    metavar: 'FILENAME'
  )
  argparser.addArgument(
    ['--quiet', '-q']
    action: 'storeTrue'
    defaultValue: false
    help: 'only output critical errors'
  )
  argparser.addArgument(
    ['--debug']
    action: 'storeTrue'
    defaultValue: false
    help: 'Show debug information'
  )
  argparser.addArgument(
    ['--json']
    action: 'storeTrue'
    defaultValue: false
    help: 'Output json log stream'
  )

  transportSubparsers = argparser.addSubparsers(
    title: 'transport'
    dest: 'transport'
  )
  for name, transport of transports
    transportParser = transportSubparsers.addParser(
      name
      addHelp: true
    )
    for name, opt of transport.options
      transportParser.addArgument(
        ["--#{camel2dash name}"]
        dest: name
        type: 'string'
        defaultValue: opt.default
        required: opt.required ? false
        help: opt.description ? ''
      )

  argparser.addArgument(
    ['input']
    type: 'string'
    metavar: 'INPUT_DIRECTORY'
  )
  args = argparser.parseArgs()

  logger = createLogger args

  if args.debug
    try
      smc = require 'source-map-support'
      smc.install()
    catch error
      logger.warn error, 'npm install source-map-support to get correct line numbers'

  if fs.existsSync args.config
    try
      config = readJSONSync args.config
    catch error
      logger.error error, "Failed loading config file: #{args.config}"
      exit 1
      return
  else
    config = {}
    if args.config?
      logger.error "Could not find config file: #{args.config}"
      exit 1
      return
  options = resolveOptions args, config, defaults

  logger.debug {options}, 'resolved options'

  transportDefaults = {}
  for key, opt of transport.options
    transportDefaults[key] = if opt.default? then opt.default else null

  transportOptions = resolveOptions args, transportConfig, transportDefaults
  transportConfig = config[normalizeTransportName(args.transport)] or {}
  logger.debug {options: transportOptions}, 'transport options'

  for key of transportOptions
    if not transportOptions[key]? and transport.options[key].required
      logger.error "Transport #{args.transport} requires option '#{key}' to be set"
      exit 1
      return

  ignore = if Array.isArray options.ignore then options.ignore else [options.ignore]

  if options.gitignore
    ignore.push '.git'
    # parse .gitignore if found
    ignoreFile = path.join args.input, '.gitignore'
    if fs.existsSync ignoreFile
      fs.readFileSync ignoreFile
        .toString()
        .split '\n'
        .filter (v) -> v.length
        .forEach (v) -> ignore.push v

  source = new nsync.FsTransport {path: args.input}
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

  logger.info "Synchronizing #{args.input} using transport #{args.transport}"

  nsync source, destination, nsyncOpts, (error) ->
    exit if error? then 1 else 0

module.exports = main
