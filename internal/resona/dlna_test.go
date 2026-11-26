package resona

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestDLNAParsingSSRFAndMetadata(t *testing.T) {
	ctx := context.Background()
	ssdp := "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: http://192.168.1.50:1400/xml/device_description.xml\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
	if got := parseSSDPLocation(ssdp); got != "http://192.168.1.50:1400/xml/device_description.xml" {
		t.Fatalf("unexpected SSDP location: %q", got)
	}
	if got := parseSSDPLocation("NOTIFY * HTTP/1.1\r\nLOCATION: http://192.168.1.50/x\r\n\r\n"); got != "" {
		t.Fatalf("expected non-200 SSDP notify to be ignored, got %q", got)
	}

	nestedXML := `<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:ZonePlayer:1</deviceType>
    <friendlyName>Root Bridge</friendlyName>
    <UDN>uuid:root-bridge</UDN>
    <deviceList>
      <device>
        <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
        <friendlyName>Living Room &amp; Studio</friendlyName>
        <manufacturer>Resona Audio</manufacturer>
        <modelName>Renderer 1</modelName>
        <UDN>uuid:living-room-renderer</UDN>
        <serviceList>
          <service>
            <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
            <controlURL>/MediaRenderer/AVTransport/Control</controlURL>
          </service>
          <service>
            <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
            <controlURL>/MediaRenderer/RenderingControl/Control</controlURL>
          </service>
        </serviceList>
      </device>
    </deviceList>
  </device>
</root>`
	dev, err := parseUPnPDeviceXML(ctx, "http://192.168.1.50:1400/xml/device.xml", []byte(nestedXML), false)
	if err != nil {
		t.Fatalf("parseUPnPDeviceXML: %v", err)
	}
	if dev.UDN != "uuid:living-room-renderer" || dev.Name != "Living Room & Studio" ||
		dev.AVTransportControl != "http://192.168.1.50:1400/MediaRenderer/AVTransport/Control" ||
		dev.RenderingControl != "http://192.168.1.50:1400/MediaRenderer/RenderingControl/Control" {
		t.Fatalf("unexpected parsed device: %+v", dev)
	}

	didl := buildDIDLLite(Track{
		ID:       "track-1",
		Title:    `Rock & Roll <Live>`,
		Artist:   `A & B`,
		Album:    `Greatest "Hits"`,
		Duration: 185,
	}, "http://192.168.1.10:8080/api/v1/dlna/media/t1/song.mp3?a=1&b=2", "http://192.168.1.10:8080/api/v1/dlna/cover/t1", "audio/mpeg")
	for _, want := range []string{"Rock &amp; Roll &lt;Live&gt;", "A &amp; B", `duration="0:03:05"`, "http://192.168.1.10:8080/api/v1/dlna/cover/t1"} {
		if !strings.Contains(didl, want) {
			t.Fatalf("DIDL-Lite missing %q: %s", want, didl)
		}
	}
	if got := formatDLNADuration(3661.4); got != "1:01:01" {
		t.Fatalf("formatDLNADuration = %q", got)
	}
	if got := parseDLNADuration("1:01:01.5"); got != 3661 {
		t.Fatalf("parseDLNADuration = %v", got)
	}

	for _, bad := range []string{
		"http://169.254.169.254/latest/meta-data/",
		"http://8.8.8.8/desc.xml",
		"ftp://192.168.1.10/desc.xml",
		"http://user:pass@192.168.1.10/desc.xml",
		"http://127.0.0.1:8080/desc.xml",
	} {
		if _, err := validateDLNAURL(ctx, bad, false); err == nil {
			t.Fatalf("expected SSRF validation to reject %q", bad)
		}
	}
	if _, err := validateDLNAURL(ctx, "http://192.168.1.20:1400/desc.xml", false); err != nil {
		t.Fatalf("expected private LAN URL to pass: %v", err)
	}
}

func TestDLNAControlAndScopedMediaTickets(t *testing.T) {
	s := testServer(t)
	s.dlna.allowLoopback = true
	h := s.Handler()
	token := loginToken(t, s)

	audioPath := filepath.Join(s.config.LibraryDir, "dlna-test.mp3")
	audioPayload := bytes.Repeat([]byte("MP3DATA"), 512)
	if err := os.WriteFile(audioPath, audioPayload, 0640); err != nil {
		t.Fatal(err)
	}
	coverPayload := []byte("\xff\xd8\xff\xe0MOCKJPEG")
	coverPath := filepath.Join(s.config.DataDir, "artwork", "dlna-track-id.jpg")
	if err := os.MkdirAll(filepath.Dir(coverPath), 0750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(coverPath, coverPayload, 0640); err != nil {
		t.Fatal(err)
	}
	s.store.mu.Lock()
	s.store.state.Tracks["dlna-track-id"] = DiskTrack{
		Track: Track{
			ID: "dlna-track-id", Title: "DLNA Song", Artist: "Tester", Album: "LAN",
			Format: "mp3", Duration: 120, Artwork: "/api/v1/tracks/dlna-track-id/cover",
		},
		File: audioPath,
	}
	s.store.mu.Unlock()

	var (
		mu             sync.Mutex
		transportState = "STOPPED"
		currentURI     string
		relTime        = "0:00:12"
		volume         = 65
		muted          = false
		soapActions    []string
	)
	var renderer *httptest.Server
	renderer = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/desc.xml":
			w.Header().Set("Content-Type", "text/xml")
			fmt.Fprintf(w, `<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Mock Bedroom Speaker</friendlyName>
    <UDN>uuid:mock-speaker</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/avtransport</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>/rendering</controlURL>
      </service>
    </serviceList>
  </device>
</root>`)
		case "/avtransport":
			bodyBytes, _ := io.ReadAll(r.Body)
			action := strings.Trim(r.Header.Get("SOAPAction"), `"`)
			if idx := strings.LastIndexByte(action, '#'); idx >= 0 {
				action = action[idx+1:]
			}
			mu.Lock()
			soapActions = append(soapActions, action)
			switch action {
			case "SetAVTransportURI":
				currentURI = soapTag(bodyBytes, "CurrentURI")
			case "Play":
				transportState = "PLAYING"
			case "Pause":
				transportState = "PAUSED_PLAYBACK"
			case "Stop":
				transportState = "STOPPED"
			case "Seek":
				relTime = soapTag(bodyBytes, "Target")
			}
			stateNow, relNow := transportState, relTime
			mu.Unlock()
			w.Header().Set("Content-Type", "text/xml")
			switch action {
			case "GetTransportInfo":
				fmt.Fprintf(w, `<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetTransportInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><CurrentTransportState>%s</CurrentTransportState><CurrentTransportStatus>OK</CurrentTransportStatus></u:GetTransportInfoResponse></s:Body></s:Envelope>`, stateNow)
			case "GetPositionInfo":
				fmt.Fprintf(w, `<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><TrackDuration>0:02:00</TrackDuration><RelTime>%s</RelTime></u:GetPositionInfoResponse></s:Body></s:Envelope>`, relNow)
			default:
				fmt.Fprintf(w, `<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:%sResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"/></s:Body></s:Envelope>`, action)
			}
		case "/rendering":
			bodyBytes, _ := io.ReadAll(r.Body)
			action := strings.Trim(r.Header.Get("SOAPAction"), `"`)
			if idx := strings.LastIndexByte(action, '#'); idx >= 0 {
				action = action[idx+1:]
			}
			mu.Lock()
			soapActions = append(soapActions, action)
			switch action {
			case "SetVolume":
				fmt.Sscanf(soapTag(bodyBytes, "DesiredVolume"), "%d", &volume)
			case "SetMute":
				muted = soapTag(bodyBytes, "DesiredMute") == "1"
			}
			vNow, mNow := volume, muted
			mu.Unlock()
			w.Header().Set("Content-Type", "text/xml")
			switch action {
			case "GetVolume":
				fmt.Fprintf(w, `<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetVolumeResponse xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><CurrentVolume>%d</CurrentVolume></u:GetVolumeResponse></s:Body></s:Envelope>`, vNow)
			case "GetMute":
				val := 0
				if mNow {
					val = 1
				}
				fmt.Fprintf(w, `<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetMuteResponse xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><CurrentMute>%d</CurrentMute></u:GetMuteResponse></s:Body></s:Envelope>`, val)
			default:
				fmt.Fprintf(w, `<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:%sResponse xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"/></s:Body></s:Envelope>`, action)
			}
		default:
			w.WriteHeader(404)
		}
	}))
	defer renderer.Close()

	// Unauthorized access must fail.
	if w := request(h, "GET", "/api/v1/dlna/devices", "", ""); w.Code != 401 {
		t.Fatalf("expected 401 for unauthenticated DLNA list, got %d", w.Code)
	}

	// Register manual DLNA renderer and verify persistence.
	if w := request(h, "POST", "/api/v1/dlna/devices/manual", fmt.Sprintf(`{"location":"%s/desc.xml"}`, renderer.URL), token); w.Code != 200 {
		t.Fatalf("manual add failed: %d %s", w.Code, w.Body.String())
	}
	reloaded := newDLNAManager(s)
	reloaded.allowLoopback = true
	if len(reloaded.settings.ManualLocations) != 1 || reloaded.settings.ManualLocations[0] != renderer.URL+"/desc.xml" {
		t.Fatalf("manual renderer did not persist: %+v", reloaded.settings)
	}

	// Save base URL override and play track on mock renderer.
	if w := request(h, "PUT", "/api/v1/dlna/settings", `{"base_url":"http://192.168.1.99:8080/"}`, token); w.Code != 200 {
		t.Fatalf("put settings failed: %d %s", w.Code, w.Body.String())
	}
	playBody := `{"udn":"uuid:mock-speaker","track_id":"dlna-track-id","position":30}`
	w := request(h, "POST", "/api/v1/dlna/play", playBody, token)
	if w.Code != 200 {
		t.Fatalf("dlna play failed: %d %s", w.Code, w.Body.String())
	}
	var st DLNAStatus
	if err := json.Unmarshal(w.Body.Bytes(), &st); err != nil || !st.Active || st.TransportState != "PLAYING" || st.Volume != 65 {
		t.Fatalf("unexpected status after play: %+v err=%v", st, err)
	}

	mu.Lock()
	mediaURI := currentURI
	mu.Unlock()
	if !strings.HasPrefix(mediaURI, "http://192.168.1.99:8080/api/v1/dlna/media/") {
		t.Fatalf("unexpected ticket media URI: %q", mediaURI)
	}

	// Fetch scoped media without login credentials, including HTTP Range 206 support.
	mediaPath := strings.TrimPrefix(mediaURI, "http://192.168.1.99:8080")
	req := httptest.NewRequest("GET", mediaPath, nil)
	req.Header.Set("Range", "bytes=0-6")
	rw := httptest.NewRecorder()
	h.ServeHTTP(rw, req)
	if rw.Code != 206 || rw.Body.String() != "MP3DATA" || rw.Header().Get("transferMode.dlna.org") != "Streaming" {
		t.Fatalf("unexpected DLNA media range response: code=%d body=%q headers=%v", rw.Code, rw.Body.String(), rw.Header())
	}

	// Issue direct client ticket and test cover fetch + logout revocation.
	tw := request(h, "POST", "/api/v1/dlna/ticket", `{"track_id":"dlna-track-id"}`, token)
	if tw.Code != 200 {
		t.Fatalf("ticket endpoint failed: %d %s", tw.Code, tw.Body.String())
	}
	var ticketResp struct {
		CoverPath string `json:"cover_path"`
	}
	if err := json.Unmarshal(tw.Body.Bytes(), &ticketResp); err != nil || ticketResp.CoverPath == "" {
		t.Fatalf("unexpected ticket response: %s", tw.Body.String())
	}
	if cw := request(h, "GET", ticketResp.CoverPath, "", ""); cw.Code != 200 || !bytes.Equal(cw.Body.Bytes(), coverPayload) {
		t.Fatalf("unexpected cover fetch: code=%d len=%d", cw.Code, cw.Body.Len())
	}

	// Control pause, seek, volume, mute, stop.
	for _, payload := range []string{
		`{"action":"pause"}`,
		`{"action":"seek","position":75}`,
		`{"action":"volume","volume":40}`,
		`{"action":"mute","muted":true}`,
		`{"action":"stop"}`,
	} {
		if cw := request(h, "POST", "/api/v1/dlna/control", payload, token); cw.Code != 200 {
			t.Fatalf("control %s failed: %d %s", payload, cw.Code, cw.Body.String())
		}
	}
	mu.Lock()
	actionsSummary := strings.Join(soapActions, ",")
	mu.Unlock()
	for _, expect := range []string{"SetAVTransportURI", "Seek", "Play", "Pause", "SetVolume", "SetMute", "Stop"} {
		if !strings.Contains(actionsSummary, expect) {
			t.Fatalf("expected SOAP action %s in %s", expect, actionsSummary)
		}
	}

	// Logout revokes issued DLNA media tickets immediately.
	if lw := request(h, "POST", "/api/v1/auth/logout", "{}", token); lw.Code != 200 {
		t.Fatalf("logout failed: %d", lw.Code)
	}
	if rw := request(h, "GET", mediaPath, "", ""); rw.Code != 404 {
		t.Fatalf("expected revoked ticket to return 404, got %d", rw.Code)
	}
}
