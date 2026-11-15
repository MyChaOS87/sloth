package main

import rego.v1

# Argo CD Application contracts
deny contains msg if {
	some e in doc_entries
	filepath := e.path
	doc := e.doc
	object.get(doc, "kind", "") == "Application"
	object.get(object.get(object.get(doc, "spec", {}), "destination", {}), "server", "") != "https://kubernetes.default.svc"
	msg := sprintf("%s: Application %s spec.destination.server must be https://kubernetes.default.svc", [filepath, doc.metadata.name])
}

deny contains msg if {
	some e in doc_entries
	filepath := e.path
	doc := e.doc
	object.get(doc, "kind", "") == "Application"
	auto := object.get(object.get(object.get(doc, "spec", {}), "syncPolicy", {}), "automated", {})
	object.get(auto, "selfHeal", false) != true
	msg := sprintf("%s: Application %s must set spec.syncPolicy.automated.selfHeal=true", [filepath, doc.metadata.name])
}

deny contains msg if {
	some e in doc_entries
	filepath := e.path
	doc := e.doc
	object.get(doc, "kind", "") == "Application"
	auto := object.get(object.get(object.get(doc, "spec", {}), "syncPolicy", {}), "automated", {})
	expected := doc.metadata.name != "nodes"
	object.get(auto, "prune", null) != expected
	msg := sprintf("%s: Application %s must set spec.syncPolicy.automated.prune=%v", [filepath, doc.metadata.name, expected])
}

deny contains msg if {
	some e in doc_entries
	filepath := e.path
	doc := e.doc
	object.get(doc, "kind", "") == "Application"
	proj := object.get(object.get(doc, "spec", {}), "project", "")
	not proj in known_projects
	msg := sprintf("%s: Application %s references unknown AppProject %q", [filepath, doc.metadata.name, proj])
}

deny contains msg if {
	some e in doc_entries
	filepath := e.path
	doc := e.doc
	endswith(concat("", ["/", filepath]), "/argocd-base/argocd.yaml")
	object.get(doc, "kind", "") == "Application"
	object.get(doc.spec.sources[0], "chart", "") != "argo-cd"
	msg := sprintf("%s: Application %s must keep argo-cd as spec.sources[0].chart (required by makefile argocd.install)", [filepath, doc.metadata.name])
}

deny contains msg if {
	some e in doc_entries
	filepath := e.path
	doc := e.doc
	object.get(doc, "kind", "") == "Application"
	some src in app_sources(doc)
	vals := src.helm.values
	not yaml.is_valid(vals)
	msg := sprintf("%s: Application %s has invalid YAML in helm.values", [filepath, doc.metadata.name])
}
