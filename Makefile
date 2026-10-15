CC = xcrun clang
CFLAGS = -std=c11 -Wall -Wextra -O2 -g -fno-objc-arc -fvisibility=hidden -mmacosx-version-min=14.0
FRAMEWORKS = -F/System/Library/PrivateFrameworks -framework Carbon -framework Cocoa -framework CoreServices -framework CoreVideo -framework QuartzCore -framework SkyLight -framework ServiceManagement -framework Security
SOURCES = vendor/yabai/src/manifest.m vendor/yabai/src/osax/payload_bin.c vendor/yabai/src/osax/loader_bin.c
HEADERS = $(shell find src vendor/yabai/src -name '*.h' -o -name '*.c' -o -name '*.m')
OSAX_DEPS = $(wildcard vendor/yabai/src/osax/*.m vendor/yabai/src/osax/*.h vendor/yabai/src/misc/*.h)

.PHONY: all test test-plane-visibility-failure test-menu-focus-guard bench clean
all: build/tana2d
vendor/yabai/src/osax/payload_bin.c: $(OSAX_DEPS)
	$(MAKE) -B -C vendor/yabai ./src/osax/payload_bin.c
# The vendored generation step writes both files. This dependency prevents two
# parallel recipes from compiling and overwriting the same generated payload.
vendor/yabai/src/osax/loader_bin.c: vendor/yabai/src/osax/payload_bin.c
	@test -f $@ || $(MAKE) -B -C vendor/yabai ./src/osax/loader_bin.c
build/tana2d: $(SOURCES) $(HEADERS)
	mkdir -p build
	$(CC) $(CFLAGS) $(SOURCES) $(FRAMEWORKS) -o $@
test:
	mkdir -p build
	$(CC) -std=c99 -Wall -Wextra -Werror -fsanitize=address,undefined -g tests/strip_geometry_test.c -o build/strip_geometry_test
	./build/strip_geometry_test
	$(CC) -std=c99 -Wall -Wextra -Werror -fsanitize=address,undefined -g tests/sa_transport_test.c -o build/sa_transport_test
	./build/sa_transport_test
	$(CC) -std=c99 -Wall -Wextra -Werror -fsanitize=address,undefined -g tests/strip_columns_test.c -o build/strip_columns_test
	./build/strip_columns_test
	$(CC) -std=c99 -Wall -Wextra -Werror -fsanitize=address,undefined -g tests/overview_geometry_test.c -o build/overview_geometry_test
	./build/overview_geometry_test
	$(CC) -std=c99 -Wall -Wextra -Werror -fsanitize=address,undefined -g tests/plane_geometry_test.c -o build/plane_geometry_test
	./build/plane_geometry_test
	$(CC) -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined tests/plane_gesture_test.c -o build/plane_gesture_test
	./build/plane_gesture_test
	$(CC) -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined tests/plane_transform_test.m -framework Cocoa -o build/plane_transform_test
	./build/plane_transform_test
	$(CC) -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined tests/plane_presentation_test.m -framework Cocoa -o build/plane_presentation_test
	./build/plane_presentation_test
	$(CC) -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g tests/strip_runtime_test.m -framework Cocoa -o build/strip_runtime_test
	./build/strip_runtime_test
	$(CC) -std=c11 -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined -g tests/plane_native_drag_test.m -framework Cocoa -o build/plane_native_drag_test
	./build/plane_native_drag_test
	$(CC) -std=c11 -Wall -Wextra -Werror -Wno-unused-function -fno-objc-arc -fblocks -fsanitize=address,undefined -g tests/plane_ax_cancel_test.m -framework Cocoa -o build/plane_ax_cancel_test
	./build/plane_ax_cancel_test
	$(CC) -std=c11 -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined -g tests/plane_snap_runtime_test.m -framework Cocoa -o build/plane_snap_runtime_test
	./build/plane_snap_runtime_test
	$(CC) -std=c11 -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined -fblocks -g tests/strip_visibility_discovery_test.m -framework Cocoa -o build/strip_visibility_discovery_test
	./build/strip_visibility_discovery_test
	$(CC) -std=c11 -Wall -Wextra -Werror -Wno-unused-function -O2 tests/strip_feedback_snapshot_test.m -framework Cocoa -o build/strip_feedback_snapshot_test
	./build/strip_feedback_snapshot_test
	$(CC) -std=c11 -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined -g tests/plane_batch_recovery_test.m -framework Cocoa -o build/plane_batch_recovery_test
	./build/plane_batch_recovery_test
	$(CC) -std=c11 -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined -g tests/plane_input_queue_test.m -framework Cocoa -o build/plane_input_queue_test
	./build/plane_input_queue_test
	$(CC) -std=c11 -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined -g tests/plane_selection_visibility_test.m -framework Cocoa -o build/plane_selection_visibility_test
	./build/plane_selection_visibility_test
	$(MAKE) test-plane-visibility-failure
	$(CC) -std=c11 -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined -g tests/plane_border_test.m -framework Cocoa -o build/plane_border_test
	./build/plane_border_test
	$(CC) -std=c11 -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined -g tests/plane_preview_test.m -framework Cocoa -o build/plane_preview_test
	./build/plane_preview_test
	$(CC) -std=c11 -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined -g tests/plane_resize_session_test.m -framework Cocoa -o build/plane_resize_session_test
	./build/plane_resize_session_test
	$(CC) -std=c11 -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined -g tests/plane_lifecycle_test.m -framework Cocoa -o build/plane_lifecycle_test
	./build/plane_lifecycle_test
	$(CC) -std=c11 -Wall -Wextra -Werror -Wno-unused-function -Wno-unused-variable -fsanitize=address,undefined -g tests/mouse_capture_test.m -framework Cocoa -o build/mouse_capture_test
	./build/mouse_capture_test
	$(CC) -std=c11 -Wall -Wextra -Werror -fno-objc-arc tests/overview_input_test.m -framework Cocoa -framework QuartzCore -o build/overview_input_test
	./build/overview_input_test
	$(CC) -Wall -Wextra -Werror -fno-objc-arc -framework Cocoa -I src src/tana_config.m tests/tana_config_test.m -o build/tana_config_test
	./build/tana_config_test
	$(CC) -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined tests/strip_workflow_model_test.c -o build/strip_workflow_model_test
	./build/strip_workflow_model_test
	$(CC) -std=c11 -Wall -Wextra -Werror -fno-objc-arc -fsanitize=address,undefined tests/strip_workflow_runtime_test.m -framework Cocoa -o build/strip_workflow_runtime_test
	./build/strip_workflow_runtime_test
	$(CC) -std=c11 -Wall -Wextra -Werror -fno-objc-arc -fblocks tests/accessibility_test.m -framework Cocoa -framework QuartzCore -o build/accessibility_test
	./build/accessibility_test
	$(CC) -std=c11 -Wall -Wextra -Werror -fno-objc-arc -fblocks tests/setup_test.m -framework Cocoa -framework ServiceManagement -o build/setup_test
	./build/setup_test
	$(CC) -std=c11 -Wall -Wextra -Werror -fno-objc-arc -fblocks tests/plane_controls_test.m -framework Cocoa -framework QuartzCore -o build/plane_controls_test
	./build/plane_controls_test
	$(MAKE) test-menu-focus-guard
	python3 -m unittest discover -s tests -p 'test_*.py'
test-menu-focus-guard:
	mkdir -p build
	$(CC) -std=c11 -Wall -Wextra -Werror -fno-objc-arc tests/menu_focus_guard_test.m -framework Cocoa -o build/menu_focus_guard_test
	./build/menu_focus_guard_test
test-plane-visibility-failure:
	mkdir -p build
	$(CC) -std=c11 -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined -g tests/plane_visibility_failure_test.m -framework Cocoa -o build/plane_visibility_failure_test
	./build/plane_visibility_failure_test
bench:
	mkdir -p build
	$(CC) -std=c11 -Wall -Wextra -Werror -O2 tests/performance_bench.c -o build/performance_bench
	./build/performance_bench
	$(CC) -std=c11 -Wall -Wextra -Werror -O2 tests/plane_snap_bench.c -o build/plane_snap_bench
	./build/plane_snap_bench
clean:
	rm -f build/tana2d build/strip_geometry_test

.PHONY: live-tools live-menu-focus
live-tools:
	mkdir -p build/Tana2DFixture.app/Contents/MacOS
	$(CC) -fno-objc-arc tests/plane_fixture.m -framework Cocoa -framework QuartzCore -o build/Tana2DFixture.app/Contents/MacOS/plane_fixture
	python3 scripts/fixture_plist.py build/Tana2DFixture.app/Contents/Info.plist
	$(CC) tests/window_metrics.m -framework Cocoa -F/System/Library/PrivateFrameworks -framework SkyLight -o build/window_metrics
	$(CC) tests/plane_gesture_probe.m -framework Cocoa -o build/plane_gesture_probe
	$(CC) tests/plane_pointer_probe.m -framework Cocoa -o build/plane_pointer_probe
	$(CC) tests/plane_hit_probe.m -framework Cocoa -F/System/Library/PrivateFrameworks -framework SkyLight -o build/plane_hit_probe
	$(CC) -fno-objc-arc -fblocks tests/live_input_projection.m -framework Cocoa -F/System/Library/PrivateFrameworks -framework SkyLight -o build/live_input_projection

	$(CC) -fno-objc-arc tests/live_transform_transaction.m -framework Cocoa -F/System/Library/PrivateFrameworks -framework SkyLight -o build/live_transform_transaction
	$(CC) -Wno-unused-function -fno-objc-arc tests/live_helper_bounds_lock.m -framework Cocoa -F/System/Library/PrivateFrameworks -framework SkyLight -o build/live_helper_bounds_lock

	$(CC) -Wno-unused-function -fobjc-arc -fblocks tests/live_native_projection.m -framework Cocoa -F/System/Library/PrivateFrameworks -framework SkyLight -o build/live_native_projection

	$(CC) -Wno-unused-function -fobjc-arc tests/live_helper_batch.m -framework Cocoa -F/System/Library/PrivateFrameworks -framework SkyLight -o build/live_helper_batch

	$(CC) -Wno-unused-function tests/live_drag_transaction.m -framework Cocoa -F/System/Library/PrivateFrameworks -framework SkyLight -o build/live_drag_transaction

live-menu-focus:
	mkdir -p build
	$(CC) -fno-objc-arc -fblocks tests/live_menu_focus.m -framework Cocoa -framework QuartzCore -o build/live_menu_focus
