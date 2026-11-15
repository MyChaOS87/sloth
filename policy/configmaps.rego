package main

import rego.v1

# Validate embedded *.json in ConfigMaps (e.g. Grafana dashboards)
deny contains msg if {
	some e in doc_entries
	filepath := e.path
	doc := e.doc
	object.get(doc, "kind", "") == "ConfigMap"
	some k, v in object.get(doc, "data", {})
	endswith(k, ".json")
	not json.is_valid(v)
	msg := sprintf("%s: ConfigMap %s data[%q] is invalid JSON", [filepath, object.get(object.get(doc, "metadata", {}), "name", "<unknown>"), k])
}
