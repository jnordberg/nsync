bunyan = require 'bunyan'
stream = require 'stream'
util = require 'util'
chalk = require 'chalk'

{TRACE, DEBUG, INFO, WARN, ERROR, FATAL} = bunyan

levelString = (level) ->
  switch level
    when TRACE
      chalk.gray 'trace'
    when DEBUG
      chalk.cyan 'debug'
    when INFO
      chalk.green ' info'
    when WARN
      chalk.yellow ' warn'
    when ERROR
      chalk.red 'error'
    when FATAL
      chalk.red.inverse 'fatal'
    else
      'unknown'

stripRecord = (record) ->
  rv = {}
  for key of record
    continue if key in ['name', 'level', 'hostname', 'pid',
                        'msg', 'time', 'v', 'src', 'err']
    rv[key] = record[key]
  return rv

humanSize = (bytes) ->
  ### Format *bytes* as a string a human can understand. ###
  rv = '0 B'
  for stuffix, num in [' B', ' kB', ' MB', ' GB', ' TB']
    size = Math.pow 1024, num
    if bytes >= size
      rv = (bytes / size).toFixed(1).replace(/\.0$/, '') + stuffix
  return rv

formatDiff = (diff) ->
  ### Format *diff* with pretty colors. ###
  rv = null
  marker = '●'
  switch diff.type
    when 'new'
      rv = "#{ chalk.green marker } #{ diff.file } #{ chalk.gray humanSize diff.size }"
    when 'change'
      rv = "#{ chalk.yellow marker } #{ diff.file } "
      delta = diff.size - diff.oldSize
      sign = if delta > 0 then '+' else '-'
      rv += chalk.gray sign + humanSize Math.abs delta
    when 'delete'
      rv = "#{ chalk.red marker } #{ diff.file }"
  return rv

class CliStream extends stream.Duplex
  ### Bunyan object-stream formatter. ###

  constructor: (debug=false) ->
    @write = @writeDebug if debug
    super()

  _read: (size) ->

  write: (record) ->
    if record.diff?
      out = formatDiff record.diff
    else
      out = record.msg
    if record.level >= ERROR
      out = "#{ chalk.red 'error' } #{ out }"
    @push out + '\n'
    return

  writeDebug: (record) ->
    out = levelString record.level
    out += ' ' + record.msg

    metadata = stripRecord record
    if Object.keys(metadata).length > 0
      out += '\n      ' + util
        .inspect metadata, {colors: true}
        .replace /\n/g, ' '
        .replace /\s\s+/g, ' '

    if record.src
      fname = record.src.func ? '(anonymous)'
      out += "\n      #{ fname } #{ record.src.file }:#{ record.src.line }"

    if record.err
      out += '\n\n      ' + record.err.stack.replace /\n/g, '\n      '

    @push out + '\n\n'
    return


createLogger = (level, outputStream) ->
  ### Create a bunyan logger using a CliStream using
      *level* and piped to *outputStream*. ###
  rawStream = new CliStream
  rawStream.pipe outputStream
  logger = bunyan.createLogger
    name: 'nsync'
    streams: [
      level: level
      type: 'raw'
      stream: rawStream
    ]
  return logger


module.exports = {CliStream, createLogger}
