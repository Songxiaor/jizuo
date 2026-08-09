#!/usr/bin/env python3
"""把 LinkDigest 打成可分发的 DMG。

和 `build-and-deploy-local.py` 的分别:那个是把产物换到本机日常使用的位置,
这个是产出一个能上传、能给别人下载的磁盘映像。两者共用同一套 bundle 组装
逻辑(`release_unit`),所以别人下载到的东西和你本机跑的是同一个装配。

签名说明:这里只做 ad-hoc 签名(`codesign -s -`)。没有 Developer ID,
所以下载方首次打开会被 Gatekeeper 拦下——DMG 里附的「安装说明」就是为此
存在的。等有了证书,把 sign_release() 换成真实身份并加公证即可,
其余流程不用动。
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NATIVE_HOST_SCRIPTS = ROOT / "scripts/native-host"
sys.path.insert(0, str(NATIVE_HOST_SCRIPTS))


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {name} from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


stable_host = load_module("stable_host", NATIVE_HOST_SCRIPTS / "stable_host.py")
release_unit = load_module("linkdigest_release_unit", NATIVE_HOST_SCRIPTS / "release_unit.py")

DMG_BACKGROUND = ROOT / "apps/desktop/Assets/DMGBackground.png"
DMG_BACKGROUND_RETINA = ROOT / "apps/desktop/Assets/DMGBackground@2x.png"
# Finder 的标题栏约 40pt；外框 760×540 对应 760×500 的背景内容区，
# 不会出现普通文件夹式的滚动条或把底部辅助文件裁掉。
DMG_WINDOW_BOUNDS = (180, 120, 940, 660)
DMG_ICON_SIZE = 96


def run(*command: str, cwd: Path | None = None) -> None:
    subprocess.run(command, check=True, cwd=cwd)


def apple_script_string(value: str) -> str:
    """把受控文件名安全地放进 AppleScript 字符串。"""
    return value.replace("\\", "\\\\").replace('"', '\\"')


def configure_finder_layout(
    mountpoint: Path, volume_name: str, app_name: str, extension_name: str
) -> None:
    """写入 Finder 的固定窗口、背景和图标位置（最终保存在 `.DS_Store`）。"""
    background = mountpoint / ".background" / DMG_BACKGROUND.name
    retina_background = mountpoint / ".background" / DMG_BACKGROUND_RETINA.name
    for candidate in (background, retina_background):
        if not candidate.is_file():
            raise RuntimeError(f"DMG 背景不存在：{candidate}")

    # `.background` 只服务 Finder，不应该作为第五个安装项显示给用户。
    run("/usr/bin/xcrun", "SetFile", "-a", "V", str(background.parent))

    left, top, right, bottom = DMG_WINDOW_BOUNDS
    script = f'''
tell application "Finder"
  tell disk "{apple_script_string(volume_name)}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set bounds of container window to {{{left}, {top}, {right}, {bottom}}}
    set viewOptions to icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to {DMG_ICON_SIZE}
    set text size of viewOptions to 13
    set label position of viewOptions to bottom
    set shows item info of viewOptions to false
    set shows icon preview of viewOptions to false
    set background picture of viewOptions to file ".background:{DMG_BACKGROUND.name}"
    set position of item "{apple_script_string(app_name)}" to {{180, 245}}
    set position of item "Applications" to {{580, 245}}
    set position of item "安装说明.txt" to {{160, 390}}
    set position of item "{apple_script_string(extension_name)}" to {{570, 390}}
    update without registering applications
    delay 2
    close
  end tell
end tell
'''
    run("/usr/bin/osascript", "-e", script)

    # Finder 关闭窗口后才落盘 `.DS_Store`；不要靠固定长等待掩盖写入失败。
    ds_store = mountpoint / ".DS_Store"
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and not ds_store.is_file():
        time.sleep(0.1)
    if not ds_store.is_file() or ds_store.stat().st_size == 0:
        raise RuntimeError("Finder 没有写入 DMG 布局元数据 `.DS_Store`")


def attach_read_write_image(image: Path) -> tuple[str, Path]:
    """挂载读写映像并返回其精确 leaf device 与 `/Volumes` 挂载点。"""
    result = subprocess.run(
        [
            "/usr/bin/hdiutil", "attach", str(image),
            "-readwrite", "-noverify", "-nobrowse", "-plist",
        ],
        check=True,
        capture_output=True,
    )
    payload = plistlib.loads(result.stdout)
    mounted = [
        entity for entity in payload.get("system-entities", [])
        if entity.get("mount-point") and entity.get("dev-entry")
    ]
    if len(mounted) != 1:
        raise RuntimeError(f"DMG 挂载结果不唯一：{mounted!r}")
    return str(mounted[0]["dev-entry"]), Path(mounted[0]["mount-point"])


def build_universal(work: Path) -> Path:
    """构建 universal 二进制,返回产物目录。

    Intel 机器上跑 arm64-only 的包会直接打不开,而下载的人里一定有 Intel Mac。
    """
    flags = ["swift", "build", "-c", "release"]
    for architecture in stable_host.SUPPORTED_ARCHITECTURES:
        flags += ["--arch", architecture]
    package = ROOT / "apps/desktop"
    run(*flags, cwd=package)
    shown = subprocess.run(
        [*flags[:2], "--show-bin-path", *flags[2:]],
        check=True, cwd=package, capture_output=True, text=True,
    )
    return Path(shown.stdout.strip())


def sign_release(app: Path, bundle_identifier: str) -> None:
    """ad-hoc 签名。

    换成真实身份时,把 "-" 替换为 "Developer ID Application: …",
    并在之后追加 notarytool submit + stapler staple 两步。
    """
    run("/usr/bin/codesign", "--force", "--deep", "--sign", "-",
        "--identifier", bundle_identifier, str(app))
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))


def sign_native_host(source: Path, destination: Path, host_name: str) -> Path:
    """签名临时副本，让 Host 包的校验和绑定签名后的 universal 二进制。"""
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    shutil.copy2(source, destination, follow_symlinks=False)
    os.chmod(destination, 0o755)
    run(
        "/usr/bin/codesign", "--force", "--sign", "-",
        "--identifier", host_name, str(destination),
    )
    run("/usr/bin/codesign", "--verify", "--strict", str(destination))
    return destination


def native_host_package(app: Path, config: dict) -> Path:
    return app / "Contents/Resources/NativeHost" / (
        f"LinkDigestNativeHost-{config['productVersion']}-macos-arm64"
    )


def verify_app_native_host(app: Path, config: dict) -> None:
    stable_host.verify_package(native_host_package(app, config), ROOT)


def sign_and_verify_app(app: Path, bundle_identifier: str, config: dict) -> None:
    sign_release(app, bundle_identifier)
    # `codesign --deep` 不会签 Resources/NativeHost；但它仍可能改变 bundle
    # 内容。最终封装后重验 Host seal，不能把先前检查当作最终事实。
    verify_app_native_host(app, config)


def create_host_package(binary_root: Path, work: Path, config: dict) -> Path:
    """签名 Host 副本并将其封装成严格校验的 universal Host package。"""
    signed_host = sign_native_host(
        binary_root / config["entrypoint"],
        work / "signed-native-host" / config["entrypoint"],
        config["hostName"],
    )
    host_package = work / "host-package" / (
        f"LinkDigestNativeHost-{config['productVersion']}-macos-arm64"
    )
    host_package.parent.mkdir(mode=0o700)
    stable_host.create_package(
        signed_host,
        binary_root / config["resourceBundle"],
        host_package,
        ROOT,
    )
    stable_host.verify_package(host_package, ROOT)
    return host_package


# 说明里出现的名字必须是**用户在 Finder 和系统弹窗里真正看到的那个**。
# App 的 CFBundleDisplayName 是「汲作」,而这份说明原本通篇写 LinkDigest——
# 于是它让用户去找「已阻止使用 LinkDigest」那一行,而系统显示的是「汲作」。
# 在一个用户已经被拦下、正在犯嘀咕的时刻,让他找一个不存在的字符串,
# 是这份说明唯一不能犯的错。名字取自 config/app-release.json,不再手写。
INSTALL_NOTE_TEMPLATE = """{name} 安装说明
====================

1. 把 {name} 拖进「应用程序」文件夹。

2. 第一次打开会被系统拦下。

   这个 App 没有购买苹果的开发者签名（99 美元/年），
   所以 macOS 会提示「无法验证开发者」，
   在某些系统版本上甚至会说「已损坏，应移到废纸篓」。

   ⚠️ 这不是文件损坏，也不是病毒。是没有付费签名的正常表现。

3. 怎么打开：

   · 双击 {name}，看到拦截提示后点「完成」或「好」
   · 打开「系统设置」→「隐私与安全性」
   · 往下滚到最底部，会看到一行
     "已阻止使用 {name}，因为来自身份不明的开发者"
   · 点它右边的「仍要打开」
   · 再确认一次，输入你的开机密码

   之后每次打开就都正常了，不用再重复。

   （macOS 15 起苹果取消了「右键→打开」这条捷径，
     只能走上面这个系统设置的路径。）

4. 浏览器扩展（可选，但推荐）

   如果你想一键保存正在看的网页/视频，需要装配套扩展：

   · 回到 {name}，打开「设置 → 浏览器支持」
   · 点「打开扩展文件夹」；{name} 会把内置扩展复制到固定位置并在 Finder 里选中
   · 打开 Chrome，地址栏输入 chrome://extensions
   · 打开右上角「开发者模式」
   · 点「加载已解压的扩展程序」，选择 Finder 刚刚选中的「{name}浏览器扩展」
   · 回到 {name}，在同一页面完成连接

5. 需要配置模型才能用总结/翻译

   打开「设置 → 模型与识别」，填入任一 OpenAI 兼容服务的
   Base URL、模型名和 API Key（DeepSeek、Kimi 等都可以）。

   视频转文字和图片文字识别在本机处理，不需要联网。
"""


def build_dmg(
    app: Path, extension: Path, output: Path, version: str, display_name: str, edition: str
) -> None:
    """组装带固定 Finder 安装界面的压缩 DMG。"""
    with tempfile.TemporaryDirectory(prefix="linkdigest-dmg-stage.", dir="/private/tmp") as tmp:
        work = Path(tmp)
        stage = work / "LinkDigest"
        stage.mkdir()
        shutil.copytree(app, stage / app.name, symlinks=False)
        shutil.copytree(extension, stage / extension.name, symlinks=False)
        # 「应用程序」的软链:让拖拽安装成为一个不用解释的动作。
        (stage / "Applications").symlink_to("/Applications")
        (stage / "安装说明.txt").write_text(
            INSTALL_NOTE_TEMPLATE.format(name=display_name), encoding="utf-8"
        )
        background_directory = stage / ".background"
        background_directory.mkdir()
        shutil.copy2(DMG_BACKGROUND, background_directory / DMG_BACKGROUND.name)
        # Finder 以基础文件名记录背景；同目录的 `@2x` 版本供 Retina 屏自动取用。
        shutil.copy2(
            DMG_BACKGROUND_RETINA,
            background_directory / DMG_BACKGROUND_RETINA.name,
        )

        if output.exists():
            output.unlink()
        read_write_image = work / "layout.dmg"
        # 用唯一的临时卷名配置 Finder，避免用户恰好仍挂载着上一个正式 DMG 时，
        # AppleScript 把布局写进旧的只读卷。布局写完后再改成正式展示名。
        layout_volume_name = f"JizuoLayout-{os.getpid()}-{edition[:1]}"
        final_volume_name = f"{display_name} {version} {edition}"
        run(
            "/usr/bin/hdiutil", "create",
            "-volname", layout_volume_name,
            "-srcfolder", str(stage),
            "-fs", "HFS+",
            "-ov", "-format", "UDRW",
            str(read_write_image),
        )

        mounted_device: str | None = None
        try:
            mounted_device, mountpoint = attach_read_write_image(read_write_image)
            configure_finder_layout(
                mountpoint, layout_volume_name, app.name, extension.name
            )
            run("/usr/sbin/diskutil", "rename", mounted_device, final_volume_name)
            run("/usr/bin/hdiutil", "detach", mounted_device)
            mounted_device = None
        finally:
            if mounted_device is not None:
                # 只做普通精确卸载，不使用 force；失败时保留现场给调用方诊断。
                subprocess.run(
                    ["/usr/bin/hdiutil", "detach", mounted_device],
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )

        run(
            "/usr/bin/hdiutil", "convert", str(read_write_image),
            "-format", "UDZO", "-imagekey", "zlib-level=9",
            "-ov", "-o", str(output),
        )


def thin_app(universal_app: Path, destination: Path, architecture: str) -> Path:
    """从已验证的 universal App 生成单架构 App，保留 universal Native Host。"""
    shutil.copytree(universal_app, destination, symlinks=False)
    binary = destination / "Contents/MacOS/LinkDigestApp"
    thinned = binary.with_name(f".{binary.name}.{architecture}.thin")
    run("/usr/bin/lipo", str(binary), "-thin", architecture, "-output", str(thinned))
    os.chmod(thinned, 0o755)
    os.replace(thinned, binary)
    actual = subprocess.check_output(["/usr/bin/lipo", "-archs", str(binary)], text=True).strip()
    if actual != architecture:
        raise RuntimeError(f"单架构切片校验失败：{binary} 是 {actual!r}，预期 {architecture!r}")

    # Native Host 的 SHA256SUMS 与 metadata 钉住 universal Mach-O；切片会破坏
    # 这个已验证包，故只验证复制后的原包仍完整，绝不重写其任何内容。
    verify_app_native_host(destination, stable_host.load_config(ROOT))
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist",
                        help="DMG 的输出目录（默认 dist/，已在 .gitignore 里）")
    parser.add_argument("--version", required=True,
                        help="版本号，例如 0.2.5；必须与 config/app-release.json 一致。")
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    config = stable_host.load_config(ROOT)
    app_config = release_unit.load_app_config(ROOT)
    if args.version != app_config["shortVersion"]:
        raise RuntimeError(
            f"--version 必须与 App 版本一致：传入 {args.version!r}，当前是 {app_config['shortVersion']!r}"
        )

    with tempfile.TemporaryDirectory(prefix="linkdigest-dmg-build.", dir="/private/tmp") as tmp:
        work = Path(tmp)
        print("→ 构建 universal 二进制（arm64 + x86_64）…")
        binary_root = build_universal(work)

        print("→ 组装 native host…")
        # 目录名沿用 `-macos-arm64`,尽管二进制已是 universal:
        # 这个名字被浏览器的 Native Messaging manifest 以绝对路径写死,
        # 改名会让已安装的扩展立刻找不到 Host。release_unit 里的校验也钉死了它。
        host_package = create_host_package(binary_root, work, config)

        print("→ 组装 App bundle…")
        staged_app = work / release_unit.APP_BUNDLE
        release_unit.build_app_bundle(
            staged_app,
            binary_root / app_config["executable"],
            binary_root / config["resourceBundle"],
            host_package,
            app_config,
            ROOT,
        )
        release_unit.verify_app(staged_app, None, ROOT, app_config)
        print("→ 准备内置浏览器扩展…")
        staged_extension = work / "汲作浏览器扩展"
        shutil.copytree(
            staged_app / "Contents/Resources" / release_unit.BROWSER_EXTENSION_DIRECTORY,
            staged_extension,
            symlinks=False,
        )

        outputs = []
        editions = [
            ("arm64", "Apple Silicon", "Apple-Silicon"),
            ("x86_64", "Intel", "Intel"),
        ]
        for architecture, edition, filename_edition in editions:
            print(f"→ 生成 {edition} App 与 DMG…")
            architecture_root = work / architecture
            architecture_root.mkdir()
            architecture_app = thin_app(
                staged_app,
                architecture_root / release_unit.APP_BUNDLE,
                architecture,
            )
            sign_and_verify_app(
                architecture_app, app_config["bundleIdentifier"], config
            )
            dmg = output_dir / f"汲作-{args.version}-macOS-{filename_edition}.dmg"
            build_dmg(
                architecture_app,
                staged_extension,
                dmg,
                args.version,
                app_config["appDisplayName"],
                edition,
            )
            outputs.append(dmg)

    for dmg in outputs:
        size_mb = dmg.stat().st_size / 1024 / 1024
        print(f"\n完成: {dmg}  ({size_mb:.1f} MB)")
    print("提醒: ad-hoc 签名，下载方首次打开需要走「系统设置 → 隐私与安全性」。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
