package main

import rego.v1

# SealedSecret (*.sealed.json) integrity
deny contains msg if {
	some e in raw_entries
	endswith(e.path, ".sealed.json")
	not is_object(e.contents)
	msg := sprintf("%s: .sealed.json file must contain a SealedSecret object", [e.path])
}

deny contains msg if {
	some e in doc_entries
	filepath := e.path
	doc := e.doc
	endswith(filepath, ".sealed.json")
	object.get(doc, "apiVersion", "") != "bitnami.com/v1alpha1"
	msg := sprintf("%s: .sealed.json must use apiVersion bitnami.com/v1alpha1 (got %v)", [filepath, object.get(doc, "apiVersion", "<missing>")])
}

deny contains msg if {
	some e in doc_entries
	filepath := e.path
	doc := e.doc
	endswith(filepath, ".sealed.json")
	object.get(doc, "kind", "") != "SealedSecret"
	msg := sprintf("%s: .sealed.json must use kind SealedSecret (got %v)", [filepath, object.get(doc, "kind", "<missing>")])
}

deny contains msg if {
	some e in doc_entries
	filepath := e.path
	doc := e.doc
	endswith(filepath, ".sealed.json")
	count(object.get(object.get(doc, "spec", {}), "encryptedData", {})) == 0
	msg := sprintf("%s: SealedSecret %s must define non-empty spec.encryptedData", [filepath, object.get(object.get(doc, "metadata", {}), "name", "<unknown>")])
}

# Ban plaintext Secrets (except hashed authelia users-secret.yaml)
deny contains msg if {
	some e in doc_entries
	filepath := e.path
	doc := e.doc
	object.get(doc, "kind", "") == "Secret"
	not is_authelia_users_secret(filepath, doc)
	msg := sprintf("%s: plaintext Kubernetes Secret %q is forbidden; seal via kubeseal into *.sealed.json", [filepath, object.get(object.get(doc, "metadata", {}), "name", "<unknown>")])
}

deny contains msg if {
	some e in doc_entries
	filepath := e.path
	doc := e.doc
	object.get(doc, "kind", "") == "Secret"
	is_authelia_users_secret(filepath, doc)
	users_yaml := object.get(object.get(doc, "stringData", {}), "users_database.yml", "")
	not yaml.is_valid(users_yaml)
	msg := sprintf("%s: authelia-users stringData['users_database.yml'] is invalid YAML", [filepath])
}

deny contains msg if {
	some e in doc_entries
	filepath := e.path
	doc := e.doc
	object.get(doc, "kind", "") == "Secret"
	is_authelia_users_secret(filepath, doc)
	users_yaml := object.get(object.get(doc, "stringData", {}), "users_database.yml", "")
	yaml.is_valid(users_yaml)
	parsed := yaml.unmarshal(users_yaml)
	some username, user in object.get(parsed, "users", {})
	pw := object.get(user, "password", "")
	not startswith(pw, "$argon2")
	msg := sprintf("%s: authelia-users user %q must store an $argon2* hash", [filepath, username])
}
