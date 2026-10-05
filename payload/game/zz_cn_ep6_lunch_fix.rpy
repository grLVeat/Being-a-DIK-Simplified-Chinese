# Compatibility fix for Vetoyi CN 0.09, Steam game 0.8.3 (Seasons 1 and 2).
# The localization changes exactly one EP6 jump from the original game.
# Restore the original destination without changing translations or save data.
init 998 python hide:
    expected_file = "season2/scripts/update6.rpy"
    expected_line = 4004
    original_target = "ep6_jill_piano_label"
    patch_target = "ep6_cleanup_label"
    candidates = [
        node for node in renpy.game.script.namemap.values()
        if isinstance(node, renpy.ast.Jump)
        and node.filename.replace("\\", "/").endswith((expected_file, expected_file + "c"))
        and node.linenumber == expected_line
        and node.target == patch_target
        and not node.expression
    ]
    if len(candidates) == 1 and renpy.has_label(original_target):
        candidates[0].target = original_target
        renpy.log("CN 0.09: restored original EP6 lunch destination at update6.rpy:4004.")
    else:
        renpy.log("CN 0.09 EP6 fix skipped: exact patch signature not found.")
