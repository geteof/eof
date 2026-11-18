#!/usr/bin/env python3
"""Builds EOF's file icons from the Material Icon Theme npm package.

Usage: Tools/material-icons.py <unpacked material-icon-theme package dir>

Get the package without running any of its scripts:
    curl -sSL "$(npm view material-icon-theme@<version> dist.tarball)" | tar xz   # -> ./package

Writes App/Resources/MaterialIcons.xcassets (one vector image set per icon that a mapping
uses, with the theme's light variant where it has one) and App/Resources/material-icons.json
(the name, extension, folder and language mappings). Re-run it to update to a newer release.
"""
import json
import os
import shutil
import sys

package = sys.argv[1]
repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
manifest = json.load(open(os.path.join(package, "dist", "material-icons.json")))
version = json.load(open(os.path.join(package, "package.json")))["version"]
definitions = manifest["iconDefinitions"]

sections = ["fileExtensions", "fileNames", "folderNames", "languageIds"]
mapping = {section: manifest[section] for section in sections}
used = {"file", "folder"}
for section in sections:
    used.update(mapping[section].values())

catalog = os.path.join(repo, "App", "Resources", "MaterialIcons.xcassets")
shutil.rmtree(catalog, ignore_errors=True)
os.makedirs(catalog)
json.dump({"info": {"author": "xcode", "version": 1}}, open(os.path.join(catalog, "Contents.json"), "w"), indent=2)


def svg_path(name):
    return os.path.normpath(os.path.join(package, "dist", definitions[name]["iconPath"]))


for name in sorted(used):
    folder = os.path.join(catalog, f"mi-{name}.imageset")
    os.makedirs(folder)
    images = []
    light = f"{name}_light"
    if light in definitions:
        # The theme's plain icon is drawn for dark backgrounds; its _light variant for light ones.
        shutil.copy(svg_path(light), os.path.join(folder, "light.svg"))
        shutil.copy(svg_path(name), os.path.join(folder, "dark.svg"))
        images.append({"filename": "light.svg", "idiom": "universal"})
        images.append({"filename": "dark.svg", "idiom": "universal",
                       "appearances": [{"appearance": "luminosity", "value": "dark"}]})
    else:
        shutil.copy(svg_path(name), os.path.join(folder, "icon.svg"))
        images.append({"filename": "icon.svg", "idiom": "universal"})
    json.dump({"images": images, "info": {"author": "xcode", "version": 1},
               "properties": {"preserves-vector-representation": True}},
              open(os.path.join(folder, "Contents.json"), "w"), indent=2)

out = {"version": version}
out.update({section: {key.lower(): value for key, value in mapping[section].items()} for section in sections})
json.dump(out, open(os.path.join(repo, "App", "Resources", "material-icons.json"), "w"), separators=(",", ":"), sort_keys=True)
print(f"material-icon-theme {version}: {len(used)} icons")
