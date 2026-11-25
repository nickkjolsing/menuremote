"""Exercise real pairing crypto without a TV or mocked authentication libraries."""

import hashlib
import unittest

from pyatv.auth.hap_srp import SRPAuthHandler
from pyatv.protocols.airplay.srp import AtvSRPContext, LegacySRPAuthHandler, new_credentials
from srptools import SRPContext, SRPServerSession, constants


class PairingDependencyTests(unittest.TestCase):
    def test_hap_pairing_agrees_on_a_key_and_proves_the_pin(self):
        context_options = dict(prime=constants.PRIME_3072,
                               generator=constants.PRIME_3072_GEN, hash_func=hashlib.sha512)
        username, verifier, salt = SRPContext("Pair-Setup", "1234", **context_options).get_user_data_triplet()
        server = SRPServerSession(SRPContext(username, **context_options), password_verifier=verifier)
        client = SRPAuthHandler()
        client.initialize()
        # This call reproduces the bundled srptools 2.0.0 constructor failure.
        client.step1("1234")
        public, proof = client.step2(bytes.fromhex(server.public), bytes.fromhex(salt))
        server.process(public.hex(), salt)
        self.assertEqual(client.shared_key, server.key)
        self.assertTrue(server.verify_proof(proof.hex().encode("ascii")))
        self.assertTrue(client.step3(name="MenuRemote"))

    def test_legacy_pairing_agrees_on_a_key_and_proves_the_pin(self):
        context_options = dict(prime=constants.PRIME_2048, generator=constants.PRIME_2048_GEN)
        username, verifier, salt = AtvSRPContext("fixture", "1234", **context_options).get_user_data_triplet()
        server = SRPServerSession(AtvSRPContext(username, **context_options), password_verifier=verifier)
        client = LegacySRPAuthHandler(new_credentials())
        client.initialize()
        client.step1(username, "1234")
        public, proof = client.step2(bytes.fromhex(server.public), bytes.fromhex(salt))
        server.process(public, salt)
        self.assertEqual(client.session.key, server.key)
        self.assertTrue(server.verify_proof(proof))


if __name__ == "__main__":
    unittest.main()
