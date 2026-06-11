#!/usr/bin/env python3
"""
scaffold_testapp.py â€” generate the pyside6-ios project files for `testapp`.

`testapp/main.py` is a bare QtWidgets app (QApplication + QLabel). The
pyside6-ios toolkit needs three things this app doesn't ship with:

  1. pyside6-ios.toml         â€” build config (QtCore/QtGui/QtWidgets modules)
  2. main.mm                  â€” custom host (QtWidgets needs QApplication, not
                                the auto-generated QGuiApplication)
  3. scripts/app.py           â€” entry script run by main.mm via PyRun_SimpleFile.
                                It must NOT create its own QApplication/argv
                                (main.mm already did) and must showFullScreen().

This script writes those into a project directory, alongside a copy of the
app's Python source as a package the toolkit can bundle.

Usage:
    python scaffold_testapp.py \
        --app-src        testapp \
        --project-dir    build/testapp-ios \
        --toolkit        /path/to/pyside6-ios \
        --qt-ios         /path/to/Qt/6.8.3/ios \
        --output-dir     generated \
        --bundle-id      com.example.testapp \
        --name           TestApp \
        --version        1.0
"""
from __future__ import annotations

import argparse
import shutil
from pathlib import Path

# ---- main.mm: QtWidgets host, derived from the toolkit's test_widgets example,
#      trimmed to the minimum testapp needs (no shiboken bindings, no native C++).
MAIN_MM = r'''// testapp iOS host (custom main.mm) â€” QtWidgets variant.
// QtWidgets requires QApplication (the auto-generated template uses
// QGuiApplication). After Python builds the UI, the Qt UIView is reparented
// into the iOS UIWindow and top-level widgets are resized to fill the screen.

#pragma push_macro("slots")
#undef slots
#include <Python.h>
#pragma pop_macro("slots")

#import <UIKit/UIKit.h>

#include <QtWidgets/QApplication>
#include <QtWidgets/QWidget>
#include <QtGui/QWindow>
#include <QtCore/QDebug>
#include <QtCore/QtPlugin>

Q_IMPORT_PLUGIN(QIOSIntegrationPlugin)

// PySide6 built-in modules (statically linked, registered as Python builtins)
extern "C" PyObject *PyInit_QtCore();
extern "C" PyObject *PyInit_QtGui();
extern "C" PyObject *PyInit_QtWidgets();
extern "C" PyObject *PyInit_Shiboken();

static QApplication *qtApp = nullptr;

static void initPython() {
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *stdlibPath = [bundlePath stringByAppendingPathComponent:@"lib/python3.13"];
    NSString *dynloadPath = [stdlibPath stringByAppendingPathComponent:@"lib-dynload"];
    NSString *appScriptsPath = [bundlePath stringByAppendingPathComponent:@"scripts"];
    NSString *appPackagesPath = [bundlePath stringByAppendingPathComponent:@"packages"];

    PyImport_AppendInittab("PySide6.QtCore", PyInit_QtCore);
    PyImport_AppendInittab("PySide6.QtGui", PyInit_QtGui);
    PyImport_AppendInittab("PySide6.QtWidgets", PyInit_QtWidgets);
    PyImport_AppendInittab("shiboken6.Shiboken", PyInit_Shiboken);

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0;
    config.home = Py_DecodeLocale([bundlePath UTF8String], NULL);

    config.module_search_paths_set = 1;
    PyWideStringList_Append(&config.module_search_paths,
        Py_DecodeLocale([stdlibPath UTF8String], NULL));
    PyWideStringList_Append(&config.module_search_paths,
        Py_DecodeLocale([dynloadPath UTF8String], NULL));
    PyWideStringList_Append(&config.module_search_paths,
        Py_DecodeLocale([appScriptsPath UTF8String], NULL));
    PyWideStringList_Append(&config.module_search_paths,
        Py_DecodeLocale([appPackagesPath UTF8String], NULL));

    PyStatus status = Py_InitializeFromConfig(&config);
    if (PyStatus_Exception(status)) {
        NSLog(@"Python init failed: %s", status.err_msg);
        return;
    }
    NSLog(@"Python %s initialized", Py_GetVersion());
}

static void runPythonApp() {
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *scriptPath = [bundlePath stringByAppendingPathComponent:@"scripts/app.py"];
    FILE *fp = fopen([scriptPath UTF8String], "r");
    if (!fp) { NSLog(@"Failed to open %@", scriptPath); return; }
    int result = PyRun_SimpleFile(fp, [scriptPath UTF8String]);
    fclose(fp);
    if (result != 0) {
        NSLog(@"Python script failed with code %d", result);
        if (PyErr_Occurred()) PyErr_Print();
    }
}

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation SceneDelegate
- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
    options:(UISceneConnectionOptions *)connectionOptions {

    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.backgroundColor = [UIColor blackColor];
    self.window.rootViewController = [[UIViewController alloc] init];
    [self.window makeKeyAndVisible];

    initPython();

    static int argc = 1;
    static const char *argv[] = {"TestApp", nullptr};
    qtApp = new QApplication(argc, const_cast<char **>(argv));
    qDebug() << "Qt" << qVersion() << "platform:" << qtApp->platformName();

    runPythonApp();

    dispatch_async(dispatch_get_main_queue(), ^{
        QWindowList windows = QGuiApplication::topLevelWindows();
        if (!windows.isEmpty()) {
            QWindow *qtWindow = windows.first();
            WId nativeId = qtWindow->winId();
            UIView *qtView = (__bridge UIView *)(void *)nativeId;
            if (qtView) {
                CGRect bounds = self.window.bounds;
                qtView.frame = bounds;
                qtView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                          UIViewAutoresizingFlexibleHeight;
                [self.window.rootViewController.view addSubview:qtView];
                QWidgetList topWidgets = QApplication::topLevelWidgets();
                for (QWidget *w : topWidgets) {
                    w->resize((int)bounds.size.width, (int)bounds.size.height);
                }
                qDebug() << "Reparented Qt view" << bounds.size.width
                         << "x" << bounds.size.height
                         << "widgets:" << topWidgets.size();
            }
        }
    });
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation AppDelegate
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
    options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *config =
        [[UISceneConfiguration alloc] initWithName:@"Default"
                                       sessionRole:connectingSceneSession.role];
    config.delegateClass = [SceneDelegate class];
    return config;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
            NSStringFromClass([AppDelegate class]));
    }
}
'''

# ---- entry script. The original testapp/main.py calls QApplication(sys.argv)
#      and sys.exit(app.exec()); on iOS the host owns both, so we adapt it:
#      grab the existing instance, build the same QLabel UI, showFullScreen().
APP_PY = r'''"""testapp iOS entry script (run by main.mm via PyRun_SimpleFile).

Adapted from testapp/main.py. The host main.mm already created the
QApplication and owns the event loop, so this script must:
  * use QApplication.instance() instead of QApplication(sys.argv)
  * NOT call app.exec()/sys.exit()
  * use showFullScreen() instead of show() (show() yields a tiny/blank window)
"""
import os
import sys


def _log(msg):
    os.write(1, (str(msg) + "\n").encode())


_log(f"Python {sys.version} on {sys.platform}")

from PySide6.QtCore import Qt
from PySide6.QtGui import QFont
from PySide6.QtWidgets import QApplication, QLabel

_log("PySide6 QtWidgets imports OK")

app = QApplication.instance()
_log(f"QApplication: {app}")

label = QLabel("Hello World!")
label.setAlignment(Qt.AlignmentFlag.AlignCenter)
label.setFont(QFont("Helvetica", 32))
label.showFullScreen()

_log("testapp loaded successfully!")
'''


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    print(f"  wrote {path}")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--app-src", required=True,
                   help="path to the extracted testapp dir (contains main.py)")
    p.add_argument("--project-dir", required=True,
                   help="where to scaffold the pyside6-ios project")
    p.add_argument("--toolkit", required=True,
                   help="path to the pyside6-ios toolkit checkout")
    p.add_argument("--qt-ios", required=True, help="path to the Qt iOS SDK")
    p.add_argument("--output-dir", default="generated",
                   help="output-dir inside the project (default: generated)")
    p.add_argument("--bundle-id", default="com.example.testapp")
    p.add_argument("--name", default="TestApp")
    p.add_argument("--version", default="1.0")
    args = p.parse_args()

    app_src = Path(args.app_src).resolve()
    proj = Path(args.project_dir).resolve()
    toolkit = Path(args.toolkit).resolve()
    qt_ios = Path(args.qt_ios).resolve()

    if not (app_src / "main.py").exists():
        print(f"ERROR: {app_src}/main.py not found")
        return 2

    proj.mkdir(parents=True, exist_ok=True)
    print(f"Scaffolding testapp project at {proj}")

    # Bundle the app's Python source as a package named `testapp`.
    pkg_dir = proj / "testapp"
    if pkg_dir.exists():
        shutil.rmtree(pkg_dir)
    pkg_dir.mkdir(parents=True)
    write(pkg_dir / "__init__.py", '"""testapp package."""\n')
    shutil.copy2(app_src / "main.py", pkg_dir / "main.py")
    print(f"  copied {app_src/'main.py'} -> {pkg_dir/'main.py'}")

    # Host + entry script
    write(proj / "main.mm", MAIN_MM)
    write(proj / "scripts" / "app.py", APP_PY)

    # Build config. Paths are written absolute so they resolve regardless of cwd.
    toml = f'''[app]
name = "{args.name}"
bundle-id = "{args.bundle_id}"
version = "{args.version}"
entry-point = ""
deployment-target = "16.0"

[paths]
pyside6-ios = "{toolkit}"
qt-ios = "{qt_ios}"
output-dir = "{args.output_dir}"

[pyside6]
modules = ["QtCore", "QtGui", "QtWidgets"]

[python]
packages = [
    {{ src = "testapp", exclude = ["*.pyc", "__pycache__"] }},
]
scripts = ["scripts/app.py"]

[sources]
main-mm = "main.mm"

[signing]
style = "Automatic"

[build-settings]
CLANG_ENABLE_MODULES = "YES"
CODE_SIGNING_ALLOWED = "NO"
CODE_SIGNING_REQUIRED = "NO"
# Fix for the final-link failure with Xcode's new linker (ld-prime):
#   ld: fixup error (kind=arm64_adrp_lo12_addend) ... target
#   'QtPrivate::QMetaTypeInterfaceWrapper<int>::metaType' does not have address
# Qt's inline static template members are weak/coalesced definitions; with
# -dead_strip the linker can strip the weak definition while a live ADRP+LO12
# reference remains, and the chained-fixups encoding cannot represent an
# address-less target. Disable dead stripping (removes the cause) and opt out
# of chained fixups (removes the encoding limitation). Belt and suspenders;
# binary is larger but correct. If size matters later, try re-enabling
# DEAD_CODE_STRIPPING first and keep -no_fixup_chains.
DEAD_CODE_STRIPPING = "NO"
OTHER_LDFLAGS = "-Wl,-no_fixup_chains"

[defines]
common = []
debug = ["DEBUG=1"]
'''
    write(proj / "pyside6-ios.toml", toml)

    print("Scaffold complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
