# this file is overwritten by a hardcoded version when compiling the coffeescript
path = require 'path'
{readJSONSync} = require './utils'
version = readJSONSync(path.join(__dirname, '../package.json')).version
module.exports = version