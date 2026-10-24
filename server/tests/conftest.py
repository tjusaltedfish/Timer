"""Tests never touch the real data folder, whatever the shell environment says."""
import os
import tempfile

# Set before any test module imports app code, so a default Store can only be
# created in this throwaway folder.
os.environ["PLANNER_DATA_DIR"] = tempfile.mkdtemp(prefix="shunshi-tests-")
os.environ.pop("PLANNER_LLM_API_KEY", None)
