async = require 'async'
fs = require 'fs'
MemoryStream = require 'memorystream'
path = require 'path'
{Stream} = require 'stream'

noop = ->

isDirectory = (filename) ->
  ### Test if *filename* is a directory. ###
  (filename[-1..] is '/')

waterfall = (chain, callback) ->
  ### Async waterfall that can finish on the same tick. ###
  idx = 0
  next = (error, result) ->
    if error? or not chain[idx]?
      callback error, result
    else
      args = [next]
      args.unshift result if result?
      chain[idx++].apply null, args
    return
  chain[idx++].call null, next
  return

workerQueue = (worker, options={}) ->
  ### Async queue implementation that handles errors. Available *options* are:
        concurrency: maximum concurrent workers running
        error: called if an error occurs
        drain: called when queue drains
        flushOnError: wether to empty the queue if an error occurs ###
  workers = 0

  add = (task, toFront) ->
    if toFront
      queue.tasks.unshift task
    else
      queue.tasks.push task
    setImmediate process
    return

  process = ->
    if workers < queue.concurrency and queue.tasks.length
      task = queue.tasks.shift()
      workers += 1
      next = (error) ->
        workers -= 1
        if error?
          queue.error error, task
          if queue.flushOnError
            queue.tasks = []
            return
        if queue.tasks.length + workers is 0
          queue.drain()
        else
          process()
        return
      worker task, next
      return

  queue =
    tasks: []
    concurrency: options.concurrency ? 1
    error: options.error ? noop
    drain: options.drain ? noop
    flushOnError: options.flushOnError ? true
    push: (task) -> add task, false
    unshift: (task) -> add task, true

  return queue

lsr = (transport, dirname, concurrency, callback) ->
  ### Calls back with an array representing *dirname* on *transport*,
      including subdirectories. *concurrency* is the maximum concurrent
      listDirectory calls that will be made on *transport*. ###
  result = []
  worker = (dir, callback) ->
    transport.listDirectory path.join(dirname, dir), (error, files) ->
      return callback error if error?
      for file in files
        filename = path.join dir, file # TODO: own path join, this wont work on windows
        if isDirectory file
          queue.push filename
        else
          result.push filename
      callback()
      return
    return

  queue = workerQueue worker, {concurrency}
  queue.error = callback
  queue.drain = -> callback null, result
  queue.push ''
  return

mkdirp = (transport, dirname, cache, callback) ->
  ### Make directory *dirname* on *transport*, including intermediate directories. ###

  isAbsolute = dirname[0] is '/'
  parts = dirname.split('/').filter (v) -> v isnt '.' and v isnt ''
  index = parts.length
  start = 0

  if arguments.length is 3
    callback = cache
    cache = {}

  findStartDir = (callback) ->
    ### Figure out which directory we need to start creating new dirs from, if any. ###
    async.until (-> start isnt 0 or index is 0), (callback) ->
      dir = parts[..index - 1].join '/'
      dir = '/' + dir if isAbsolute
      if cache[dir]
        start = index
        return callback()
      transport.listDirectory dir, (error, list) ->
        if error?
          index--
        else
          start = index
          start++ if parts[index] + '/' in list
        callback()
    , callback

  createDirectores = (callback) ->
    ### Create directories in *parts* starting from *start*. ###
    create = []
    for i in [start...parts.length]
      create.push parts[..i].join '/'
    async.forEachSeries create, (dir, callback) ->
      dir = '/' + dir if isAbsolute
      cache[dir] = true
      transport.makeDirectory dir, callback
    , callback

  async.series [findStartDir, createDirectores], callback

cp = (source, destination, fromFile, toFile, callback) ->
  ### Copy *fromFile* on *source* transport to *toFile* on *destination* transport. ###
  if source.createReadStream?
    destination.putFile toFile, source.createReadStream(fromFile), callback
  else
    waterfall [
      (callback) -> source.getFile fromFile, callback
      (result, callback) ->
        # memorystream if buffer, else - pump dat
        if result instanceof Stream
          destination.putFile toFile, result, callback
        else
          stream = new MemoryStream
          destination.putFile toFile, stream, callback
          setImmediate -> stream.end result
    ], callback

getStream = (source, filename, callback) ->
  ### Callback with a readable stream for *filename* on *source* transport. ###
  if source.createReadStream?
    callback null, source.createReadStream(filename)
  else
    waterfall [
      (callback) -> source.getFile filename, callback
      (result, callback) ->
        if result instanceof Stream
          callback null, result
        else
          stream = new MemoryStream
          callback null, stream
          setImmediate -> stream.end result
    ], callback

fetchFile = (source, filename, callback) ->
  ### Fetch *filename* on *source* transport and read it to memory. ###
  if source.createReadStream?
    readStream source.createReadStream(filename), callback
  else
    waterfall [
      (callback) -> source.getFile fromFile, callback
      (result, callback) ->
        if result instanceof Stream
          readStream result, callback
        else
          callback null, result
    ], callback

readStream = (stream, callback) ->
  ### Reads *stream* into a Buffer. ###
  parts = []
  stream.on 'error', (error) ->
    callback? error
    callback = null
  stream.on 'data', (data) -> parts.push data
  stream.on 'end', ->
    callback? null, Buffer.concat(parts)
    callback = null
  return

parseJSON = (buffer, callback) ->
  ### Async-ish version of JSON.parse. ###
  try
    rv = JSON.parse buffer.toString()
  catch error
    error.message = "JSON parse error: #{ error.message }"
    return callback error
  callback null, rv

stringifyJSON = (object, callback) ->
  ### Async-ish version of JSON.stringify. ###
  try
    json = JSON.stringify object, null, 2
  catch error
    return callback error
  callback null, json

extend = (object, mixin) ->
  ### Extend *object* with values from *mixin*. ###
  for name, method of mixin
    object[name] = method
  return

readJSON = (filename, callback) ->
  ### Read and try to parse *filename* as JSON, *callback* with parsed object or error on fault. ###
  waterfall [
    (callback) ->
      fs.readFile filename, callback
    (buffer, callback) ->
      try
        rv = JSON.parse buffer.toString()
        callback null, rv
      catch error
        error.filename = filename
        error.message = "parsing #{ path.basename(filename) }: #{ error.message }"
        callback error
  ], callback

readJSONSync = (filename) ->
  ### Synchronously read and parse *filename* as json. ###
  buffer = fs.readFileSync filename
  return JSON.parse buffer.toString()

writeJSONSync = (filename, object) ->
  ### Synchronously stringify *object* to json and write it to *filename*. ###
  fs.writeFileSync filename, JSON.stringify(object, null, 2)


### Exports ###

module.exports = {
  cp, extend, fetchFile, getStream
  lsr, mkdirp, parseJSON, readJSON, readJSONSync, readStream
  stringifyJSON, waterfall, workerQueue, writeJSONSync
}
