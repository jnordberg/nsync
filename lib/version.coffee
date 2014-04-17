path = require 'path'
{readJSONSync} = require './utils'
version = readJSONSync(path.join(__dirname, '../package.json')).version
module.exports = version
