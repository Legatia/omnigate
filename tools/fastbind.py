"""Make http.server's servers start without a reverse DNS lookup.

`HTTPServer.server_bind` calls `socket.getfqdn` on the address it bound, only
to fill in `server_name`. For 127.0.0.1 that lookup takes many seconds on
some machines (macOS on GitHub's runners), once per server, and the test
tools start more than a dozen servers. Importing this module replaces the
method with one that binds and takes the name from the address.

Standard library only.
"""

import http.server
import socketserver


def _server_bind(self):
    socketserver.TCPServer.server_bind(self)
    host, port = self.server_address[:2]
    self.server_name = host
    self.server_port = port


http.server.HTTPServer.server_bind = _server_bind
