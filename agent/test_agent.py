# regression check: python agent/test_agent.py   (the key-name table must stay a dict: it once got shadowed by the Esc-menu queue and press_key Enter failed)
import importlib.util
spec = importlib.util.spec_from_file_location("hmagent", __file__.replace("test_agent.py", "agent.py")); m = importlib.util.module_from_spec(spec)
try: spec.loader.exec_module(m)
except SystemExit: pass
assert isinstance(m.KEYS, dict) and m.KEYS["enter"] == "Return", "KEYS must be the key-name table"
assert hasattr(m, "KEYQ"), "the Esc-menu queue is KEYQ"
print("agent key table ok")
import json, os, time
if os.path.isdir("/proc/self"):   # Linux: the live System panel snapshot reads /proc
    m.sys_snap(); time.sleep(0.3); j = json.loads(m.sys_snap())
    assert j["ramTotal"] > 0 and j["n"] > 0 and 0 <= j["mem"] <= 100 and 0 <= j["cpu"] <= 100, j
    assert all(len(r) == 7 and isinstance(r[1], str) and r[6] in ("", "!") for r in j["p"]), j["p"][:2]
    assert os.getpid() in [r[0] for r in j["p"]] or j["p"], "the snapshot lists processes"
    print("system snapshot ok")
