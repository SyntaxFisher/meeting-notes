import contextlib
import io
import json
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from server import Handler, Server


class HostingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = Server(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = "http://127.0.0.1:" + str(cls.server.server_port)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def test_association(self):
        with urlopen(self.base + "/.well-known/apple-app-site-association") as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.headers["Content-Type"], "application/json")
            details = json.load(response)["applinks"]["details"]
            self.assertEqual(details[0]["appIDs"], ["94DW6CHJD7.com.jona.meeting-notes"])
            self.assertEqual(details[0]["components"], [{"/": "/meeting/*"}])

    def test_fallback_does_not_reflect_or_log_identifiers(self):
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors):
            with urlopen(self.base + "/meeting/private-test-id?p=s4") as response:
                content = response.read()
                self.assertNotIn(b"private-test-id", content)
                self.assertNotIn(b"s4", content)
                self.assertEqual(response.headers["Cache-Control"], "no-store")
                self.assertEqual(response.headers["Referrer-Policy"], "no-referrer")
                self.assertNotIn("Location", response.headers)
        self.assertEqual(errors.getvalue(), "")

    def test_only_public_assets_are_served(self):
        for path in ["/server.py", "/../server.py", "/.well-known/../server.py", "/config"]:
            with self.assertRaises(HTTPError) as error:
                urlopen(self.base + path)
            self.assertEqual(error.exception.code, 404)
            error.exception.close()

    def test_head(self):
        with urlopen(Request(self.base + "/meeting/example", method="HEAD")) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.read(), b"")


if __name__ == "__main__":
    unittest.main()
