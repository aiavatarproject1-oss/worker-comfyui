"""Dual-protocol dispatch: classic API vs ComfyUI-RunOnRunpod plugin."""

import os
import sys
import types
import unittest
from unittest.mock import MagicMock, patch

# Stub heavy/optional deps before importing handler (no network needed for unit tests).
for _mod_name in (
    "runpod",
    "runpod.serverless",
    "runpod.serverless.utils",
    "websocket",
    "requests",
):
    if _mod_name not in sys.modules:
        sys.modules[_mod_name] = types.ModuleType(_mod_name)

_runpod = sys.modules["runpod"]
_runpod.serverless = sys.modules["runpod.serverless"]
_runpod.serverless.progress_update = MagicMock()
_runpod.serverless.start = MagicMock()
sys.modules["runpod.serverless.utils"].rp_upload = MagicMock()

_requests = sys.modules["requests"]
_requests.get = MagicMock()
_requests.post = MagicMock()
_requests.RequestException = type("RequestException", (Exception,), {})

sys.modules["websocket"].WebSocket = MagicMock
sys.modules["websocket"].WebSocketException = type("WebSocketException", (Exception,), {})
sys.modules["websocket"].WebSocketTimeoutException = type(
    "WebSocketTimeoutException", (Exception,), {}
)
sys.modules["websocket"].WebSocketConnectionClosedException = type(
    "WebSocketConnectionClosedException", (Exception,), {}
)
sys.modules["websocket"].enableTrace = MagicMock()

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "src"))

import handler  # noqa: E402


class TestDualProtocolDispatch(unittest.TestCase):
    def test_version_action_does_not_require_workflow(self):
        with patch.object(handler, "wait_for_comfy", return_value=True), patch.dict(
            os.environ,
            {
                "PROTOCOL_VERSION": "1",
                "WORKER_VERSION": "9.9.9",
                "COMFYUI_VERSION": "test",
            },
            clear=False,
        ):
            result = handler.handler({"id": "j1", "input": {"action": "version"}})

        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["protocol_version"], 1)
        self.assertEqual(result["worker_version"], "9.9.9")
        self.assertEqual(result["received_input"], {"action": "version"})
        self.assertNotIn("error", result)

    def test_version_action_echoes_full_received_input(self):
        payload = {
            "action": "version",
            "workflow": {"1": {"class_type": "KSampler"}},
            "extra": {"debug": True},
        }
        with patch.object(handler, "wait_for_comfy", return_value=True), patch.dict(
            os.environ,
            {"PROTOCOL_VERSION": "1", "WORKER_VERSION": "9.9.9", "COMFYUI_VERSION": "test"},
            clear=False,
        ):
            result = handler.handler({"id": "j1", "input": payload})

        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["received_input"], payload)

    def test_node_list_action(self):
        with patch.object(handler, "get_node_list", return_value=["KSampler", "VAELoader"]):
            result = handler.handler({"id": "j1", "input": {"action": "node_list"}})

        self.assertEqual(result["node_list"], ["KSampler", "VAELoader"])

    def test_classic_missing_workflow_still_errors(self):
        result = handler.handler(
            {"id": "j1", "input": {"images": [{"name": "a.png", "image": "x"}]}}
        )
        self.assertEqual(result["error"], "Missing 'workflow' parameter")

    def test_input_files_key_routes_to_volume_path(self):
        with patch.object(
            handler,
            "run_volume_workflow",
            return_value={
                "status": "success",
                "output_count": 0,
                "output_files": [],
            },
        ) as mock_vol:
            result = handler.handler(
                {
                    "id": "j1",
                    "input": {
                        "workflow": {"1": {"class_type": "Fake"}},
                        "input_files": {},
                    },
                }
            )

        mock_vol.assert_called_once()
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["output_files"], [])

    def test_classic_workflow_does_not_hit_volume_path(self):
        """Requests without the input_files key keep the classic path."""
        with patch.object(handler, "run_volume_workflow") as mock_vol, patch.object(
            handler, "check_server", return_value=False
        ):
            result = handler.handler(
                {"id": "j1", "input": {"workflow": {"1": {"class_type": "Fake"}}}}
            )

        mock_vol.assert_not_called()
        self.assertIn("not reachable", result["error"])

    def test_fetch_models_action(self):
        fake_results = {
            "action": "fetch_models",
            "total": 0,
            "results": [],
        }
        with patch.object(handler, "run_fetch_models", return_value=fake_results) as mock_fetch:
            result = handler.handler(
                {"id": "j1", "input": {"action": "fetch_models", "downloads": []}}
            )

        mock_fetch.assert_called_once()
        self.assertEqual(result, fake_results)


if __name__ == "__main__":
    unittest.main()
