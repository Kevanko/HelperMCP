# regression check: python agent/test_agent.py   (the key-name table must stay a dict: it once got shadowed by the Esc-menu queue and press_key Enter failed)
import importlib.util
spec = importlib.util.spec_from_file_location("hmagent", __file__.replace("test_agent.py", "agent.py")); m = importlib.util.module_from_spec(spec)
try: spec.loader.exec_module(m)
except SystemExit: pass
assert isinstance(m.KEYS, dict) and m.KEYS["enter"] == "Return", "KEYS must be the key-name table"
assert hasattr(m, "KEYQ"), "the Esc-menu queue is KEYQ"
print("agent key table ok")
