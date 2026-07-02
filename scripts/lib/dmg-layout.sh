#!/bin/bash

create_styled_dmg() {
    local app_path="$1"
    local dmg_path="$2"
    local volume_name="$3"
    local staging_dir="$4"
    local project_dir="$5"

    local helper_script="$project_dir/scripts/create-styled-dmg.sh"
    local app_name

    app_name="$(basename "$app_path")"

    if [ ! -x "$helper_script" ]; then
        chmod +x "$helper_script"
    fi

    if [ ! -d "$app_path" ]; then
        echo "ERROR: App bundle not found at $app_path"
        return 1
    fi

    rm -f "$dmg_path"
    rm -rf "$staging_dir"
    mkdir -p "$staging_dir"

    cp -R "$app_path" "$staging_dir/"
    ln -s /Applications "$staging_dir/Applications"

    "$helper_script" \
        --volname "$volume_name" \
        --source "$staging_dir" \
        --output "$dmg_path" \
        --app-name "$app_name"

    rm -rf "$staging_dir"
}
