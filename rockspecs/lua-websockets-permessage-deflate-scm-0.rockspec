package = "lua-websockets-permessage-deflate"
version = "scm-0"

source = {
  url = "git://github.com/moteus/lua-websockets-permessage-deflate.git",
}

description = {
  summary = "WebSocket permessage-deflate extension",
  homepage = "https://github.com/moteus/lua-websockets-permessage-deflate",
  license = "MIT/X11",
  detailed = ""
}

dependencies = {
  "lua >= 5.1, < 5.4",
}

build = {
  type = "builtin",

  modules = {
    ['websocket.extensions.permessage-deflate'] = 'src/websocket/extensions/permessage-deflate.lua',
  }
}
