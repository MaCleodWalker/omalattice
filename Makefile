.PHONY: test test-qml check

QMLTESTRUNNER ?= qmltestrunner

# Keep the tests independent of the user's own overrides.
test: export OMALATTICE_CONFIG := /nonexistent/omalattice/config.lua
test:
	lua tests/run.lua
	lua tests/hyprland_adapter.lua
	lua tests/omarchy_integration.lua
	lua tests/pan_direction.lua
	lua tests/pan_lifecycle.lua
	lua tests/hover.lua
	lua tests/settings.lua
	lua tests/persist.lua
	bash tests/installer.sh

test-qml:
	QT_QPA_PLATFORM=offscreen $(QMLTESTRUNNER) -input tests/tst_minimap_drag.qml

check: test
	luac -p layout/*.lua integration/*.lua tests/*.lua
	bash -n install.sh uninstall.sh tests/installer.sh
	python3 -m json.tool manifest.json >/dev/null
	test -f Service.qml
	test -f MinimapDrag.qml
	test -f MinimapInput.qml
	test -f Widget.qml
	@if command -v omarchy >/dev/null 2>&1; then omarchy plugin validate .; fi
