# Simplified Chinese text revision for Steam 0.8.3, Seasons 1 and 2.
# Data is applied to display strings only. Story conditions/flags are untouched.
init 997 python hide:
    import json
    import os
    import re
    from collections import defaultdict

    if os.environ.get("BADIK_CN_STAGE") or renpy.loadable("cn_polished/COMPLETE"):
        with renpy.file("cn_polished/cn_polished.json") as stream:
            data = json.load(stream)
        translator = renpy.game.script.translator
        report = {"version": config.version, "translated_blocks": 0, "fallback_blocks": 0, "extra_blocks": 0, "strings": 0, "missing": [], "mismatched": []}

        def normalize(path):
            path = path.replace("\\", "/")
            if path.startswith("game/"):
                path = path[5:]
            if path.endswith(".rpyc"):
                path = path[:-1]
            return path

        original_nodes = defaultdict(list)
        for identifier, block in translator.default_translates.items():
            for node in block.block:
                if isinstance(node, renpy.ast.Say):
                    key = (normalize(node.filename), node.linenumber, node.who, node.what)
                    original_nodes[key].append((identifier, node))

        for unit in data["dialogue"]:
            block = translator.language_translates.get((unit["id"], "chinese"))
            nodes = [n for n in block.block if isinstance(n, renpy.ast.Say)] if block is not None else []
            if len(nodes) == 1 and nodes[0].what == unit["previous"]:
                nodes[0].what = unit["zh"]
                report["translated_blocks"] += 1
            elif block is None:
                report["missing"].append(unit["id"])
            else:
                report["mismatched"].append(unit["id"])
            # Small English edits changed translation identifiers in Steam 0.8.3.
            # Fill the unmatched original statement without changing its control flow.
            key = (normalize(unit["file"]), unit["line"], unit["who"], unit["en"])
            for original_id, node in original_nodes.get(key, []):
                if (original_id, "chinese") not in translator.language_translates:
                    node.what = unit["zh"]
                    report["fallback_blocks"] += 1

        for identifier, text in data.get("extras", {}).items():
            block = translator.language_translates.get((identifier, "chinese"), translator.default_translates.get(identifier))
            nodes = [n for n in block.block if isinstance(n, renpy.ast.Say)] if block is not None else []
            if len(nodes) == 1:
                nodes[0].what = text
                report["extra_blocks"] += 1
            else:
                report["missing"].append(identifier)

        string_translator = translator.strings["chinese"]
        string_translator.translations.update(data["strings"])
        report["strings"] = len(data["strings"])

        # Chat renders emotes separately and removes their tokens before Text sees it.
        # Translate the whole display string first; keep stored messages untouched.
        if hasattr(store, "mphone_get_chat_str"):
            original_chat = store.mphone_get_chat_str
            phone_strings = data.get("phone_strings", {})
            def translated_chat(text, _original=original_chat, _strings=phone_strings):
                return _original(_strings.get(text, text))
            store.mphone_get_chat_str = translated_chat

        # Dynamic UI templates are rendered with user values already substituted.
        # Only full strings matching a reviewed template can be rewritten.
        templates = []
        for template in data.get("templates", []):
            templates.append((re.compile(template["pattern"], re.DOTALL), template["parts"]))
        if templates:
            original_translate = string_translator.translate
            def translate_dynamic(text, _original=original_translate, _templates=templates):
                result = _original(text)
                if result != text:
                    return result
                for pattern, parts in _templates:
                    match = pattern.match(text)
                    if match:
                        return u"".join(match.group(part) if isinstance(part, int) else part for part in parts)
                return result
            string_translator.translate = translate_dynamic

        output = os.environ.get("BADIK_CN_REPORT")
        if output:
            with open(output, "wb") as stream:
                stream.write(json.dumps(report, ensure_ascii=False, indent=2).encode("utf-8"))
