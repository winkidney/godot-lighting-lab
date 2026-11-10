PYTHON ?= python3

.PHONY: run editor import validate capture video video-check video-tts video-assemble video-preview video-render video-encode video-verify video-records video-covers video-bgm
run:
	$(PYTHON) tools/run.py run $(if $(MODULE),--module $(MODULE),)
editor:
	$(PYTHON) tools/run.py editor
import:
	$(PYTHON) tools/run.py import
validate:
	$(PYTHON) tools/run.py validate
capture:
	$(PYTHON) tools/run.py capture $(if $(ONLY),--only $(ONLY),)

# Tutorial video (see video/pipeline.py): narration via Asset Workbench, Movie Maker render.
video:
	$(PYTHON) video/pipeline.py all
video-check:
	$(PYTHON) video/pipeline.py check
video-tts:
	$(PYTHON) video/pipeline.py tts
video-assemble:
	$(PYTHON) video/pipeline.py assemble
video-preview:
	$(PYTHON) video/pipeline.py preview --chapter $(or $(CH),c0) $(if $(FROM),--from $(FROM),)
video-render:
	$(PYTHON) video/pipeline.py render $(if $(CH),--chapter $(CH),) $(if $(JOBS),--jobs $(JOBS),)
video-encode:
	$(PYTHON) video/pipeline.py encode
video-verify:
	$(PYTHON) video/pipeline.py verify
video-records:
	$(PYTHON) video/pipeline.py records
video-covers:
	$(PYTHON) video/build_covers.py
video-bgm:
	$(PYTHON) video/mix_bgm.py $(if $(SRC),--source "$(SRC)",)
