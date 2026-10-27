package resona

import (
	_ "embed"
	"encoding/json"
)

//go:embed VERSION.json
var versionJSON []byte

type VersionInfo struct {
	Version string `json:"version"`
	Build   int    `json:"build"`
}

func Version() VersionInfo {
	var v VersionInfo
	if err := json.Unmarshal(versionJSON, &v); err != nil || v.Version == "" || v.Build < 1 {
		panic("invalid embedded VERSION.json")
	}
	return v
}
