async = require 'async'
crypto = require 'crypto'
MemoryStream = require 'memorystream'
path = require 'path'

{waterfall, getStream, lsr, stringifyJSON,
 parseJSON, readStream} = require './utils'

hashStream = (stream, callback) ->
  ### Calculates a sha1 checksum for *stream*. ###
  hash = crypto.createHash 'sha1'
  hash.setEncoding 'hex'
  size = 0
  stream.on 'data', (data) ->
    size += data.length
  stream.on 'error', callback
  stream.on 'end', ->
    hash.end()
    callback null, [size, hash.read()]
  stream.pipe hash
  return

class Manifest

  constructor: (@files={}, @lastUpdate) ->
    @lastUpdate ?= Date.now()

  toFile: (filename, transport, callback) ->
    ### Writes this manifest instance to a JSON file named *filename*
        using *transport*, calls *callback* when done or on error. ###
    waterfall [
      (callback) => stringifyJSON @serialize(), callback
      (json, callback) ->
        buffer = new Buffer json
        stream = new MemoryStream
        transport.putFile filename, buffer.length, stream, callback
        setImmediate -> stream.end buffer
    ], callback

  serialize: -> {@files, @lastUpdate}

  lookup: (filename) ->
    file = @files[filename]
    if file?
      return {file: filename, size: file[0], hash: file[1]}
    return null

Manifest.fromFile = (filename, transport, callback) ->
  ### Calls back with a Manifest instance created from a JSON file
      named *filename* using *transport*. ###
  waterfall [
    (callback) -> getStream transport, filename, callback
    readStream
    parseJSON
    (data, callback) ->
      callback null, new Manifest(data.files, data.lastUpdate)
  ], callback

Manifest.fromDirectory = (dirname, transport, concurrency, callback) ->
  ### Calls back with a Manifest instance created
      from a *dirname* using *transport*. ###
  waterfall [
    (callback) -> lsr transport, dirname, concurrency, callback
    (result, callback) ->
      files = {}
      async.forEachLimit result, concurrency, (file, callback) ->
        filename = path.join dirname, file
        waterfall [
          (callback) -> getStream transport, filename, callback
          hashStream
          (hash, callback) ->
            files[file] = hash
            callback()
        ], callback
      , (error) ->
        manifest = new Manifest(files) unless error?
        callback error, manifest
  ], callback

Manifest.diff = (oldManifest, newManifest) ->
  ### Return a array with differences between *oldManifest* and *newManifest*. ###
  diff = []
  for filename, newInfo of newManifest.files
    oldInfo = oldManifest.files[filename]
    if oldInfo?
      if oldInfo[1] isnt newInfo[1]
        diff.push
          type: 'change'
          file: filename
          hash: newInfo[1]
          oldHash: oldInfo[1]
          size: newInfo[0]
          oldSize: oldInfo[0]
    else
      diff.push
        type: 'new'
        file: filename
        hash: newInfo[1]
        oldHash: null
        size: newInfo[0]
        oldSize: 0
  for filename, oldInfo of oldManifest.files
    newInfo = newManifest.files[filename]
    if not newInfo?
      diff.push
        type: 'delete'
        file: filename
        hash: null
        oldHash: oldInfo[1]
        size: 0
        oldSize: oldInfo[0]
  return diff

# Exports

module.exports = {Manifest}
