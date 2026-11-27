from django.test import TestCase


class VerifyPageTests(TestCase):
    def test_verify_page_renders_form_without_tx(self):
        resp = self.client.get("/verify/")
        self.assertEqual(resp.status_code, 200)
        self.assertContains(resp, "Public PQ verification")

    def test_verify_page_invalid_tx_does_not_500(self):
        resp = self.client.get("/verify/", {"tx": "0x" + "00" * 32})
        self.assertEqual(resp.status_code, 200)

    def test_verify_route_named(self):
        from django.urls import reverse

        self.assertEqual(reverse("blockchain:verify"), "/verify/")
