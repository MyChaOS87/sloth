package main

import rego.v1

kairos_k3s_versions contains ver if {
	some e in doc_entries
	doc := e.doc
	object.get(doc, "kind", "") == "NodeOpUpgrade"
	img := object.get(object.get(doc, "spec", {}), "image", "")
	matches := regex.find_all_string_submatch_n("-k3s-(v[0-9]+\\.[0-9]+\\.[0-9]+)-([a-z0-9]+)$", img, 1)
	count(matches) == 1
	ver := sprintf("%s+%s", [matches[0][1], matches[0][2]])
}

deny contains msg if {
	some e in doc_entries
	filepath := e.path
	doc := e.doc
	object.get(doc, "kind", "") == "NodeOpUpgrade"
	img := object.get(object.get(doc, "spec", {}), "image", "")
	count(regex.find_all_string_submatch_n("-k3s-(v[0-9]+\\.[0-9]+\\.[0-9]+)-([a-z0-9]+)$", img, 1)) == 0
	msg := sprintf("%s: NodeOpUpgrade %s spec.image (%q) must end with -k3s-vX.Y.Z-k3sN tag suffix for K3s parity checks", [filepath, doc.metadata.name, img])
}

deny contains msg if {
	some e in doc_entries
	filepath := e.path
	doc := e.doc
	object.get(doc, "apiVersion", "") == "upgrade.cattle.io/v1"
	object.get(doc, "kind", "") == "Plan"
	object.get(object.get(doc, "spec", {}), "channel", "") != ""
	msg := sprintf("%s: Plan %s must pin explicit spec.version rather than floating spec.channel", [filepath, doc.metadata.name])
}

deny contains msg if {
	some e in doc_entries
	filepath := e.path
	doc := e.doc
	object.get(doc, "apiVersion", "") == "upgrade.cattle.io/v1"
	object.get(doc, "kind", "") == "Plan"
	object.get(object.get(doc, "spec", {}), "version", "") == ""
	msg := sprintf("%s: Plan %s must set explicit spec.version", [filepath, doc.metadata.name])
}

deny contains msg if {
	some e in doc_entries
	filepath := e.path
	doc := e.doc
	object.get(doc, "apiVersion", "") == "upgrade.cattle.io/v1"
	object.get(doc, "kind", "") == "Plan"
	plan_ver := object.get(object.get(doc, "spec", {}), "version", "")
	plan_ver != ""
	some kairos_ver in kairos_k3s_versions
	plan_ver != kairos_ver
	msg := sprintf("%s: Plan %s spec.version (%q) must match Kairos NodeOpUpgrade K3s version (%q)", [filepath, doc.metadata.name, plan_ver, kairos_ver])
}
