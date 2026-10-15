"""Opt-in native NSMenu/submenu regression; requires a running Tana2D.

Build with `make live-menu-focus live-tools`, then run this script manually.
It opens native menus and custom popups in two disposable fixture processes,
crosses between their surfaces, and restores the prior cursor, focus, camera,
zoom, and configuration. It never invokes a menu item or changes an existing
application window's geometry.
"""
import json
import hashlib
import subprocess
import sys
import tempfile
import time
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WM = ROOT / 'build/tana2d'
TOOL = ROOT / 'build/live_menu_focus'
HIT_PROBE = ROOT / 'build/plane_hit_probe'
REPORT_PATH = ROOT / 'build/menu-focus-live.json'


def call(*args):
    return subprocess.check_output([str(WM), '-m', *map(str, args)], text=True)


def windows():
    return json.loads(call('query', '--windows'))


def strip(*args):
    return json.loads(call('strip', *args))


def wait(predicate, timeout=4, message='timed out waiting for live fixture state'):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.025)
    raise AssertionError(message)


def read(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def command(pid, name):
    subprocess.run([str(TOOL), 'command', str(pid), name], check=True)


def move(x, y):
    subprocess.run([str(TOOL), 'move', str(x), str(y)], check=True)


def presentation(window_id):
    return strip('presentation-status', window_id)


def settle(window_id, timeout=4):
    """Wait until the reported transform has stopped changing."""
    previous = None
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = presentation(window_id)
        signature = tuple(state.get(key) for key in (
            'worldX', 'worldY', 'worldWidth', 'worldHeight',
            'displayedX', 'displayedY', 'displayedWidth', 'displayedHeight',
            'cameraX', 'cameraY', 'cameraScale'))
        busy = any(state.get(key) for key in ('drag', 'nativeDrag', 'nativeMovePending', 'transformDirty'))
        if signature == previous and not busy:
            return state
        previous = signature
        time.sleep(.025)
    raise AssertionError(f'window {window_id} presentation did not settle')


def fixture_window(pid):
    return next((w for w in windows() if w.get('pid') == pid), None)


def plane_fixture_window(pid):
    managed_ids = {w['id'] for w in strip('status')['windows']}
    return next((w for w in windows() if w.get('pid') == pid and w['id'] in managed_ids), None)


def frame_for(window):
    displays = json.loads(call('query', '--displays'))
    display = next(d for d in displays if d['index'] == window['display'])
    frame = display['frame']
    return {'x': frame['x'], 'y': frame['y'],
            'width': frame.get('width', frame.get('w')),
            'height': frame.get('height', frame.get('h'))}


def center(state):
    return (state['displayedX'] + state['displayedWidth'] / 2,
            state['displayedY'] + state['displayedHeight'] / 2)


def contained(state, frame, inset=4):
    return (frame['x'] + inset <= state['displayedX'] and
            frame['y'] + inset <= state['displayedY'] and
            state['displayedX'] + state['displayedWidth'] <= frame['x'] + frame['width'] - inset and
            state['displayedY'] + state['displayedHeight'] <= frame['y'] + frame['height'] - inset)


def hit_probe(x, y, expected_id):
    output = subprocess.check_output([str(HIT_PROBE), str(x), str(y)], text=True)
    first = output.splitlines()[0] if output.splitlines() else ''
    assert f'id={expected_id} ' in first, f'WindowServer hit mismatch at ({x}, {y}): {first}'
    return first


def position_owned_windows(owner_id, target_id, follow_mode):
    """Place disposable fixtures and center target from the reported transform."""
    owner_world = (10000, 10000, 460, 300)
    target_world = (10470, 10000, 460, 300)
    call('strip', 'place', owner_id, *owner_world)
    call('strip', 'place', target_id, *target_world)
    call('strip', 'zoom', 1)
    call('strip', 'camera', 9700, 9800)
    target = settle(target_id)

    owner_window = next(w for w in windows() if w['id'] == owner_id)
    frame = frame_for(owner_window)
    # Center is required for focusAfterScroll=center. A 1440px display leaves
    # both 460px fixture surfaces on screen with the deliberately small gap.
    assert frame['width'] >= 1400, f'display too narrow for isolated fixture: {frame}'
    desired_x = frame['x'] + frame['width'] / 2
    desired_y = frame['y'] + frame['height'] / 2
    actual_x, actual_y = center(target)
    call('strip', 'camera',
         target['cameraX'] + (actual_x - desired_x) / target['cameraScale'],
         target['cameraY'] + (actual_y - desired_y) / target['cameraScale'])
    target = settle(target_id)
    owner = settle(owner_id)
    assert contained(target, frame), f'target center/surface outside display: {target}'
    assert contained(owner, frame), f'owner surface outside display: {owner}'
    target_center = center(target)
    hit = hit_probe(*target_center, target_id)
    if follow_mode == 'center':
        assert abs(target_center[0] - desired_x) < 3 and abs(target_center[1] - desired_y) < 3, target
    return owner, target, frame, hit


def config_follow_mode(config):
    path = Path(config['path'])
    raw = path.read_bytes()
    document = json.loads(raw)
    settings = document.get('settings', {})
    mode = settings.get('focusAfterScroll', 'none')
    assert mode in ('center', 'pointer', 'none'), f'invalid focusAfterScroll {mode!r} in {path}'
    # The pending-queue assertion needs a configured automatic scroll path.
    # Preserve exact bytes and refuse to overwrite a concurrently changed file.
    temporary = None
    if mode == 'none':
        assert path.read_bytes() == raw, f'config changed while preparing fixture: {path}'
        settings = dict(settings); settings['focusAfterScroll'] = 'pointer'
        document['settings'] = settings
        temporary = json.dumps(document, indent=2, ensure_ascii=False).encode() + b'\n'
        path.write_bytes(temporary)
        call('strip', 'reload-config')
        mode = 'pointer'
    return mode, {'path': path, 'original': raw, 'temporary': temporary,
                  'original_sha256': hashlib.sha256(raw).hexdigest()}


def compact_position(state):
    return {key: state[key] for key in (
        'worldX', 'worldY', 'worldWidth', 'worldHeight',
        'displayedX', 'displayedY', 'displayedWidth', 'displayedHeight',
        'cameraX', 'cameraY', 'cameraScale') if key in state}


def same_camera(before, after):
    return all(abs(float(before[key]) - float(after[key])) < .01 for key in ('x', 'y', 'scale'))


def restore_camera(camera):
    deadline = time.monotonic() + 4
    last_error = None
    while time.monotonic() < deadline:
        try:
            call('strip', 'zoom', camera['scale'])
            call('strip', 'camera', camera['x'], camera['y'])
            state = strip('status')
            if same_camera(camera, state['camera']):
                return state
        except subprocess.CalledProcessError as error:
            last_error = error
        time.sleep(.05)
    raise AssertionError(f'camera did not restore: {last_error!r}')


def dismiss_owned_menu(status_path, owner_point):
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if not (read(status_path) or {}).get('menuOpen'):
            return
        # Click the labelled blank centre of our disposable owner fixture, never
        # a menu item or a user application, to dismiss nested native tracking.
        subprocess.run([str(TOOL), 'click', str(owner_point[0]), str(owner_point[1])], check=True)
        time.sleep(.12)
    raise AssertionError('owned native menu did not dismiss after Escape')


def popup_state(status_path, visible=None, alpha_zero=None):
    def current():
        state = read(status_path) or {}
        if not state.get('popupPresent'):
            return None
        if visible is not None and state.get('popupVisible') != visible:
            return None
        if alpha_zero is True and state.get('popupAlpha', 1) > .001:
            return None
        if alpha_zero is False and state.get('popupAlpha', 0) <= .001:
            return None
        return state
    return wait(current, message='fixture popup did not reach the requested state')


def clear_pointer_hold(point):
    time.sleep(.4)
    move(*point)
    return wait(lambda: (state if not state['focusGuard'] else None)
                if (state := strip('focus-status')) else None,
                message='owned pointer movement did not clear the ordinary focus hold')


def run_popup_cases(owner_info, owner_window, target_window, owner_status, report):
    """Exercise only owned NSPanel surfaces and explicit fixture focus."""
    call('window', owner_window['id'], '--focus')
    wait(lambda: next((w for w in windows() if w['id'] == owner_window['id'] and w.get('has-focus')), None))
    owner_state, target_state, _, _ = position_owned_windows(owner_window['id'], target_window['id'], 'pointer')
    target_center = center(target_state)

    command(owner_info['pid'], 'popup-open')
    visible = popup_state(owner_status, visible=True, alpha_zero=False)
    bounds = visible['popupBounds']
    assert bounds['width'] > 800 and bounds['height'] > 800, f'popup did not exceed old size cap: {bounds}'
    hit = hit_probe(*target_center, target_window['id'])
    popup_point = (max(20, bounds['x']+bounds['width']/2), bounds['y']+bounds['height']/2)
    guard = clear_pointer_hold(popup_point)
    assert guard['popupSuppressed'] and not guard['menuSuppressed'], guard
    move(target_center[0]+12, target_center[1]+12)
    time.sleep(.2)
    held = read(owner_status) or {}
    assert held.get('popupPresent') and held.get('frontPid') == owner_info['pid'], (
        'visible custom popup lost owner focus during target hover', held)
    report['popup'] = {'visible': visible, 'visible_target_hit': hit,
                       'visible_hover_held': held, 'ordinary_focus_hold_cleared': guard}

    # Direct manager focus is explicit intent and must not be blocked by a popup.
    call('window', target_window['id'], '--focus')
    wait(lambda: next((w for w in windows() if w['id'] == target_window['id'] and w.get('has-focus')), None),
         message='explicit focus to owned target was blocked by custom popup')
    command(owner_info['pid'], 'popup-close')
    wait(lambda: not (read(owner_status) or {}).get('popupPresent'),
         message='visible custom popup did not close')
    call('window', owner_window['id'], '--focus')
    wait(lambda: next((w for w in windows() if w['id'] == owner_window['id'] and w.get('has-focus')), None))
    # Explicit focus can move the camera. Re-measure the actual hover target.
    owner_state, target_state, _, _ = position_owned_windows(owner_window['id'], target_window['id'], 'pointer')
    target_center = center(target_state)
    hit_probe(*target_center, target_window['id'])
    report['popup']['post_close_position'] = compact_position(target_state)
    report['popup']['before_recovery_hover'] = clear_pointer_hold(center(owner_state))
    move(target_center[0]+12, target_center[1]+12)
    wait(lambda: next((w for w in windows() if w['id'] == target_window['id'] and w.get('has-focus')), None),
         message='hover did not resume after visible custom popup closed')

    call('window', owner_window['id'], '--focus')
    wait(lambda: next((w for w in windows() if w['id'] == owner_window['id'] and w.get('has-focus')), None))
    owner_state, target_state, _, _ = position_owned_windows(owner_window['id'], target_window['id'], 'pointer')
    hidden_center = center(target_state)
    command(owner_info['pid'], 'popup-alpha-zero')
    hidden = popup_state(owner_status, visible=True, alpha_zero=True)
    guard = clear_pointer_hold(center(owner_state))
    assert not guard['popupSuppressed'] and not guard['menuSuppressed'], guard
    move(hidden_center[0]+12, hidden_center[1]+12)
    wait(lambda: next((w for w in windows() if w['id'] == target_window['id'] and w.get('has-focus')), None),
         message='alpha-zero custom popup incorrectly suppressed hover focus')
    command(owner_info['pid'], 'popup-close')
    wait(lambda: not (read(owner_status) or {}).get('popupPresent'),
         message='alpha-zero custom popup did not close')
    return {'visible': visible, 'visible_target_hit': hit, 'visible_hover_held': held,
            'explicit_focus_allowed': True, 'visible_close_allows_hover': True, 'alpha_zero': hidden,
            'alpha_zero_allows_hover': True}


def main():
    assert TOOL.exists() and HIT_PROBE.exists(), 'run make live-menu-focus live-tools first'
    initial = strip('status')
    initial_pointer = json.loads(subprocess.check_output([str(TOOL), 'pointer'], text=True))
    initial_ffm = call('config', 'focus_follows_mouse').strip()
    initial_windows = windows()
    initial_focus = next((w['id'] for w in initial_windows if w.get('has-focus')), None)
    initial_config = strip('config-status')
    assert initial_config.get('autofocus') != 'off', 'live menu regression requires autofocus to be enabled'
    follow_mode, config_file = config_follow_mode(initial_config)
    initial_camera = dict(initial['camera'])
    managed_ids = {w['id'] for w in initial['windows']}
    initial_positions = {window_id: compact_position(presentation(window_id)) for window_id in managed_ids}
    report = {
        'result': 'incomplete', 'initial_camera': initial_camera, 'initial_focus': initial_focus,
        'initial_config': initial_config, 'focus_after_scroll': follow_mode,
        'config_sha256': config_file['original_sha256'],
        'temporary_focus_after_scroll': config_file['temporary'] is not None,
        'fixture_cleanup': False, 'restored': False,
    }
    processes = []
    owner_info = target_info = owner_window = target_window = None
    primary_error = None
    with tempfile.TemporaryDirectory(prefix='tana2d-menu-focus-') as directory:
        owner_status = Path(directory) / 'owner.json'
        target_status = Path(directory) / 'target.json'
        try:
            target = subprocess.Popen([str(TOOL), str(target_status)]); processes.append(target)
            target_info = wait(lambda: read(target_status))
            owner = subprocess.Popen([str(TOOL), str(owner_status)]); processes.append(owner)
            owner_info = wait(lambda: read(owner_status))
            owner_window = wait(lambda: plane_fixture_window(owner_info['pid']),
                                message='owner fixture never joined the plane')
            target_window = wait(lambda: plane_fixture_window(target_info['pid']),
                                 message='target fixture never joined the plane')

            call('window', owner_window['id'], '--focus')
            wait(lambda: next((w for w in windows() if w['id'] == owner_window['id'] and w.get('has-focus')), None))
            owner_state, target_state, frame, hit = position_owned_windows(
                owner_window['id'], target_window['id'], follow_mode)
            report.update(owner_pid=owner_info['pid'], target_pid=target_info['pid'],
                          owner_window=owner_window['id'], target_window=target_window['id'],
                          owner_position=compact_position(owner_state),
                          target_position=compact_position(target_state),
                          display_frame=frame, target_windowserver_hit=hit)

            # Keep the pointer untouched until the menu is visibly open. This
            # separates the native-menu holding path from the later hover test.

            command(owner_info['pid'], 'open')
            menu_status = wait(lambda: (status if status.get('menuOpen') and status.get('frontPid') == owner_info['pid'] else None)
                               if (status := read(owner_status)) else None,
                               message='native root menu did not remain owner-front when opened')
            bounds = wait(lambda: (read(owner_status) or {}).get('menuBounds'),
                          message='fixture did not report actual root-menu bounds')
            # The fixture opens its attached NSMenu submenu on the menu's common
            # event-tracking loop; the delegate status below is the assertion.
            report.update(menu_bounds=bounds, submenu_open_method='native-tracking-loop',
                          menu_status_before_submenu=read(owner_status) or {})
            time.sleep(.25)
            report['menu_status_after_submenu_request'] = read(owner_status) or {}
            submenu_status = wait(lambda: (read(owner_status) or {}).get('submenuOpen'),
                                  message='native submenu did not actually open')
            assert submenu_status is True

            # A one-pixel absolute scroll while the real native menu/submenu is
            # open must neither enqueue nor deliver automatic focus.
            scroll_from = presentation(owner_window['id'])
            scroll_request = scroll_from['cameraX'] + 1
            call('strip', 'scroll', scroll_request)
            scroll_state = strip('status')
            assert abs(scroll_state['camera']['x'] - scroll_request) < .01, (
                'strip scroll no longer accepts an absolute camera target', scroll_state, scroll_request)
            time.sleep(.2)
            guarded_scroll_status = read(owner_status) or {}
            assert guarded_scroll_status.get('menuOpen') and guarded_scroll_status.get('frontPid') == owner_info['pid'], (
                'automatic focus crossed a displayed native menu', guarded_scroll_status)
            assert not presentation(owner_window['id']).get('navigationPending'), 'automatic queue was retained while menu open'

            # The scroll may have shifted the camera by one pixel. Re-sample and
            # prove the exact crossing coordinate reaches the owned target.
            crossing_state = presentation(target_window['id'])
            crossing_center = center(crossing_state)
            crossing_hit = hit_probe(*crossing_center, target_window['id'])
            move(*crossing_center)
            time.sleep(.2)
            during = read(owner_status) or {}
            assert during.get('menuOpen') and during.get('frontPid') == owner_info['pid'], (
                'menu lost focus while crossing fixture surface', during)
            assert not presentation(owner_window['id']).get('navigationPending'), 'automatic queue survived menu open'
            report.update(menu_bounds=bounds, submenu_open=submenu_status,
                          crossed_target=target_window['id'], crossing_position=compact_position(crossing_state),
                          crossing_windowserver_hit=crossing_hit, scroll_request=scroll_request,
                          scroll_camera_after_request=scroll_state['camera'], menu_status=menu_status,
                          guarded_scroll_status=guarded_scroll_status,
                          during=during)

            dismiss_owned_menu(owner_status, center(owner_state))
            # Native click dismissal installs the normal short focus hold; move
            # only after it expires so this checks ordinary hover behavior.
            time.sleep(.4)
            move(crossing_center[0] + 12, crossing_center[1] + 12)
            wait(lambda: next((w for w in windows() if w['id'] == target_window['id'] and w.get('has-focus')), None),
                 message='hover did not focus target after menu close')
            popup_report = run_popup_cases(owner_info, owner_window, target_window, owner_status, report)
            report.update(result='pass', closed_allows_future_hover=True, popup=popup_report)
        except BaseException as error:
            primary_error = error
            report.update(result='failed', error=repr(error), traceback=traceback.format_exc())
            try:
                report['focus_diagnostic'] = strip('focus-status')
            except BaseException:
                pass
        finally:
            restoration_errors = []
            try:
                call('config', 'focus_follows_mouse', 'off')
            except BaseException as error:
                restoration_errors.append(f'disable hover during cleanup: {error!r}')
            try:
                if owner_status and (read(owner_status) or {}).get('menuOpen'):
                    dismiss_owned_menu(owner_status, center(owner_state))
                if owner_status and (read(owner_status) or {}).get('popupPresent'):
                    command(owner_info['pid'], 'popup-close')
                for process in processes:
                    if process.poll() is None:
                        command(process.pid, 'quit')
                for process in processes:
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        process.terminate(); process.wait(timeout=2)
                fixture_pids = {info['pid'] for info in (owner_info, target_info) if info}
                wait(lambda: not any(w.get('pid') in fixture_pids for w in windows()), 3,
                     'owned fixture windows remained after quit')
                report['fixture_cleanup'] = True
            except BaseException as error:
                restoration_errors.append(f'fixture cleanup: {error!r}')
            try:
                if config_file['temporary'] is not None:
                    path = config_file['path']
                    if path.read_bytes() != config_file['temporary']:
                        restoration_errors.append('config changed externally while the fixture was running; left it untouched')
                    else:
                        path.write_bytes(config_file['original'])
                        call('strip', 'reload-config')
                call('config', 'focus_follows_mouse', 'off')
                if initial_focus and any(w['id'] == initial_focus for w in windows()):
                    call('window', initial_focus, '--focus')
                final = restore_camera(initial_camera)
                report['final_camera'] = final['camera']
            except BaseException as error:
                restoration_errors.append(f'restore: {error!r}')
                report.update(restoration_errors=restoration_errors, restored=False)
            try:
                subprocess.run([str(TOOL), 'warp', str(initial_pointer['x']), str(initial_pointer['y'])], check=True)
                restored_pointer = json.loads(subprocess.check_output([str(TOOL), 'pointer'], text=True))
                assert all(abs(restored_pointer[key]-initial_pointer[key]) < .51 for key in ('x', 'y'))
                report['pointer_restored'] = True
            except BaseException as error:
                restoration_errors.append(f'pointer restore: {error!r}')
                report.update(restoration_errors=restoration_errors, restored=False, pointer_restored=False)
            try:
                call('config', 'focus_follows_mouse', 'off' if initial_ffm == 'disabled' else initial_ffm)
                final_config = strip('config-status')
                if final_config != initial_config:
                    restoration_errors.append('config-status changed during fixture run')
                final_windows = windows()
                final_focus = next((w['id'] for w in final_windows if w.get('has-focus')), None)
                if initial_focus and any(w['id'] == initial_focus for w in final_windows) and final_focus != initial_focus:
                    restoration_errors.append(f'focus changed: before={initial_focus} after={final_focus}')
                for window_id, before in initial_positions.items():
                    if any(w['id'] == window_id for w in final_windows):
                        after = compact_position(presentation(window_id))
                        for key in ('worldX', 'worldY', 'worldWidth', 'worldHeight'):
                            if key in before and abs(float(before[key]) - float(after[key])) > .01:
                                restoration_errors.append(f'window {window_id} {key} changed: {before[key]} -> {after[key]}')
                                break
                report.update(final_focus=final_focus, final_config=final_config)
            except BaseException as error:
                restoration_errors.append(f'restore hover: {error!r}')
            report.update(restoration_errors=restoration_errors, restored=not restoration_errors)
    REPORT_PATH.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return 1 if primary_error or not report.get('restored') else 0


if __name__ == '__main__':
    sys.exit(main())
