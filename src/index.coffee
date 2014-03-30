async = require 'async'
{Ignore} = require 'ignore'
path = require 'path'

version = require './version'
{Manifest} = require './manifest'
{mkdirp, getStream,} = require './utils'
{Transport, FsTransport} = require './transport'


defaults =
  # where to store and load manifest file on destination transport
  # can be set to a falsey value to disable manifest usage
  manifest: 'manifest.json'

  # force a manifest rebuild, useful if destination files and destination manifest
  # has lost their state. has no effect if manifest is not used
  forceRebuild: false

  # maximum number of concurrent operations run on transports
  concurrency: 4

  # delete files and directories on destination transport
  destructive: false

  # directory to sync files from on source transport
  sourcePath: './'

  # directory to sync files to on destination transport
  destinationPath: './'

  # files to ignore, can use .gitignore style matching, eg dir/**/*.xls
  ignore: ['.git', '.DS_Store']

  # if enabled will not touch anything on the destination
  pretend: false

  # bunyan logger, defaults to a logger that logs errors to stdout
  logger: null

createLogger = ->
  bunyan = require 'bunyan'
  logger = bunyan.createLogger
    name: 'nsync'
    streams: [
      {stream: process.stderr, level: 'debug'}
    ]
  return logger

nsync = (source, destination, options, callback) ->
  ### Synchronize *source* transport to *destination* transport using *options*.
      Calls *callback* when done or if an error occurs. ###

  if arguments.length is 3
    callback = options
    options = {}

  for key of defaults
    options[key] ?= defaults[key]

  pretend = options.pretend
  manifests = null
  dircache = {}
  logger = options.logger ? createLogger()
  ignore = new Ignore
    twoGlobstars: true
    ignore: options.ignore

  start = process.hrtime()
  stats =
    added: 0
    modified: 0
    removed: 0
    bytesTransfered: 0

  done = (error) ->
    stats.time = process.hrtime start
    if error?
      logger.fatal error
    else
      logger.info {stats}, 'Done!'
    callback error, stats

  logger.debug {options}, 'Version %s', version

  useManifest = !!options.manifest
  if useManifest
    manifestPath = path.join options.destinationPath, options.manifest
    ignore.addPattern options.manifest

  # give transports logger instances
  source.logger = logger.child {transport: Transport.getName(source)}
  destination.logger = logger.child {transport: Transport.getName(destination)}

  validateTransports = (callback) ->
    logger.debug 'Validating transports'
    try
      Transport.validate source
      Transport.validate destination
    catch error
    callback error

  setupTransports = (callback) ->
    logger.debug 'Setup transports'
    async.parallel [
      (callback) -> source.setup callback
      (callback) -> destination.setup callback
    ], callback

  loadManifests = (callback) ->
    logger.debug 'Loading manifests'
    async.parallel
      source: (callback) ->
        # source manifests are always created from directory for comparison
        logger.debug 'Building source manifest from %s', options.sourcePath
        Manifest.fromDirectory options.sourcePath, source, options.concurrency, callback
      destination: (callback) ->
        async.waterfall [
          (callback) ->
            if useManifest and not options.forceRebuild
              logger.debug 'Loading manifest from destination'
              Manifest.fromFile manifestPath, destination, (error, manifest) ->
                if error?
                  logger.debug "No manifest found, rebuilding"
                callback null, manifest
            else
              callback null, null
          (manifest, callback) ->
            if not manifest?
              logger.debug "Building manifest from destination"
              Manifest.fromDirectory options.destinationPath, destination, options.concurrency, callback
            else
              callback null, manifest
        ], callback
    , (error, result) ->
      manifests = result unless error?
      callback error

  syncFiles = (callback) ->
    logger.debug 'Building diff'
    diffs = Manifest.diff manifests.destination, manifests.source
    test = ignore.createFilter()
    logger.debug {patterns: ignore._patterns}, 'Filtering out ignored files'
    diffs = diffs.filter (diff) ->
      if not test diff.file
        logger.trace "Ignoring #{ diff.file }"
        return false
      return true

    logger.debug "Diff size: #{ diffs.length }"

    if diffs.length is 0
      logger.info "Already syncrhonized, exiting..."
      return callback()

    makeDirectores = (callback) ->
      newDirectories = diffs
        .filter (diff) -> diff.type is 'new'
        .map (diff) -> path.dirname path.join(options.destinationPath, diff.file)
        .filter (dir, idx, arr) -> arr.indexOf(dir) is idx
      # TODO: figure out which directories can be created in parallel
      #       and try to saturate transport concurrency
      async.forEachSeries newDirectories, (dir, callback) ->
        logger.debug "Creating directory: #{ dir }"
        if not pretend
          mkdirp destination, dir, dircache, callback
        else
          callback()
      , callback

    removeEmpty = (callback) ->
      toDelete = diffs
        .filter (diff) -> diff.type is 'delete'
        .map (diff) -> path.dirname path.join(options.destinationPath, diff.file)
        .filter (dir, idx, arr) -> arr.indexOf(dir) is idx
      async.forEachSeries toDelete, (dir, callback) ->
        async.waterfall [
          (callback) -> destination.listDirectory dir, callback
          (items, callback) ->
            if items.length is 0
              logger.debug "Removing empty directory: #{ dir }"
              if not pretend
                destination.deleteDirectory dir, callback
              else
                callback()
            else
              callback()
        ], callback
      , callback

    handleDiff = (diff, callback) ->
      toFile = path.join options.destinationPath, diff.file
      fromFile = path.join options.sourcePath, diff.file
      logger.debug "#{ fromFile } -> #{ toFile }"
      switch diff.type
        when 'new', 'change'
          logger.info {diff}, '%s: %s', diff.type, diff.file
          stats.added += 1 if diff.type is 'new'
          stats.modified += 1 if diff.type is 'change'
          stats.bytesTransfered += diff.size
          if not pretend
            async.waterfall [
              (callback) -> getStream source, fromFile, callback
              (stream, callback) -> destination.putFile toFile, diff.size, stream, callback
            ], callback
          else
            callback()
        when 'delete'
          if options.destructive
            stats.removed += 1
            logger.info {diff}, '%s: %s', diff.type, diff.file
            if not pretend
              destination.deleteFile toFile, callback
            else
              callback()
          else
            callback()
        else
          callback new Error "Unknown diff type: #{ diff.type }"

    preserveDeletions = (callback) ->
      # called when not in destructive mode to keep the deleted files in the
      # destination transport (adds to source manif since it will be written later)
      for diff in diffs when diff.type is 'delete'
        manifests.source.files[diff.file] = [diff.oldSize, diff.oldHash]
      callback()

    flow = []
    flow.push makeDirectores
    flow.push (callback) -> async.forEachLimit diffs, options.concurrency, handleDiff, callback
    flow.push removeEmpty if options.destructive
    flow.push preserveDeletions if not options.destructive

    async.series flow, callback
    return

  saveManifest = (callback) ->
    # write source manifest as new destination manifest
    return callback() if not useManifest
    logger.debug "Writing manifest to destination (#{ manifestPath })"
    if not pretend
      async.series [
        (callback) -> mkdirp destination, path.dirname(manifestPath), dircache, callback
        (callback) -> manifests.source.toFile manifestPath, destination, callback
      ], callback
    else
      callback()

  cleanup = (callback) ->
    logger.debug 'Cleanup transports'
    async.parallel [
      (callback) -> source.cleanup callback
      (callback) -> destination.cleanup callback
    ], callback

  async.series [
    validateTransports
    setupTransports
    loadManifests
    syncFiles
    saveManifest
    cleanup
  ], done
  return


### Exports ###

module.exports = nsync
module.exports.defaults = defaults
module.exports.version = version
module.exports.Manifest = Manifest
module.exports.Transport = Transport
module.exports.FsTransport = FsTransport
