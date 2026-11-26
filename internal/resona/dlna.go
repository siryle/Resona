package resona

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	dlnaAVTransportService      = "urn:schemas-upnp-org:service:AVTransport:1"
	dlnaRenderingControlService = "urn:schemas-upnp-org:service:RenderingControl:1"
	dlnaMediaRendererType       = "urn:schemas-upnp-org:device:MediaRenderer:1"
	dlnaTicketTTL               = 6 * time.Hour
	dlnaTicketLimit             = 64
	dlnaFeaturesFlags           = "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
)

type DLNADevice struct {
	UDN                string `json:"udn"`
	Name               string `json:"name"`
	Manufacturer       string `json:"manufacturer,omitempty"`
	Model              string `json:"model,omitempty"`
	Location           string `json:"location"`
	AVTransportControl string `json:"av_transport_control"`
	RenderingControl   string `json:"rendering_control,omitempty"`
	Manual             bool   `json:"manual"`
}

type DLNAStatus struct {
	Active         bool    `json:"active"`
	DeviceUDN      string  `json:"device_udn,omitempty"`
	DeviceName     string  `json:"device_name,omitempty"`
	TrackID        string  `json:"track_id,omitempty"`
	TrackTitle     string  `json:"track_title,omitempty"`
	TrackArtist    string  `json:"track_artist,omitempty"`
	TransportState string  `json:"transport_state,omitempty"`
	Position       float64 `json:"position"`
	Duration       float64 `json:"duration"`
	Volume         int     `json:"volume"`
	Muted          bool    `json:"muted"`
	Error          string  `json:"error,omitempty"`
}

type dlnaSettings struct {
	BaseURL         string   `json:"base_url,omitempty"`
	ManualLocations []string `json:"manual_locations,omitempty"`
}

type dlnaTicket struct {
	TrackID string
	Expires time.Time
	Created time.Time
}

type dlnaManager struct {
	server        *Server
	settingsPath  string
	httpClient    *http.Client
	allowLoopback bool

	mu          sync.Mutex
	settings    dlnaSettings
	devices     map[string]DLNADevice
	scanned     bool
	tickets     map[string]dlnaTicket
	activeUDN   string
	activeTrack Track
}

func newDLNAManager(s *Server) *dlnaManager {
	m := &dlnaManager{
		server:       s,
		settingsPath: filepath.Join(s.config.DataDir, "dlna.json"),
		httpClient: &http.Client{
			Timeout: 5 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
		devices: map[string]DLNADevice{},
		tickets: map[string]dlnaTicket{},
	}
	if data, err := os.ReadFile(m.settingsPath); err == nil {
		var parsed dlnaSettings
		if json.Unmarshal(data, &parsed) == nil {
			if parsed.BaseURL != "" {
				if norm, err := normalizeDLNABaseURL(parsed.BaseURL); err == nil {
					parsed.BaseURL = norm
				} else {
					parsed.BaseURL = ""
				}
			}
			m.settings = parsed
		}
	}
	return m
}

func normalizeDLNABaseURL(raw string) (string, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", nil
	}
	u, err := url.Parse(trimmed)
	if err != nil {
		return "", errors.New("invalid URL")
	}
	if (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("DLNA URL must be http or https without credentials, query or fragment")
	}
	u.Path = strings.TrimRight(u.Path, "/")
	return u.String(), nil
}

func isAllowedDLNAAddr(addr netip.Addr, allowLoopback bool) bool {
	addr = addr.Unmap()
	if !addr.IsValid() || addr.IsUnspecified() || addr.IsMulticast() {
		return false
	}
	if addr == netip.MustParseAddr("169.254.169.254") {
		return false
	}
	if addr.IsLoopback() {
		return allowLoopback
	}
	return addr.IsPrivate() || addr.IsLinkLocalUnicast()
}

func validateDLNAURL(ctx context.Context, raw string, allowLoopback bool) (*url.URL, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" || u.User != nil {
		return nil, errors.New("DLNA 设备地址无效，仅支持局域网 http 或 https 地址")
	}
	host := u.Hostname()
	if addr, err := netip.ParseAddr(host); err == nil {
		if !isAllowedDLNAAddr(addr, allowLoopback) {
			return nil, errors.New("仅允许访问局域网内的 DLNA 设备地址")
		}
		return u, nil
	}
	lookupCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	addrs, err := net.DefaultResolver.LookupNetIP(lookupCtx, "ip", host)
	if err != nil || len(addrs) == 0 {
		return nil, errors.New("无法解析 DLNA 设备地址")
	}
	for _, addr := range addrs {
		if !isAllowedDLNAAddr(addr, allowLoopback) {
			return nil, errors.New("仅允许访问局域网内的 DLNA 设备地址")
		}
	}
	return u, nil
}

func parseSSDPLocation(packet string) string {
	lines := strings.Split(packet, "\n")
	if len(lines) == 0 {
		return ""
	}
	status := strings.TrimSpace(lines[0])
	if !strings.HasPrefix(strings.ToUpper(status), "HTTP/1.") {
		return ""
	}
	for _, line := range lines[1:] {
		idx := strings.IndexByte(line, ':')
		if idx <= 0 {
			continue
		}
		key := strings.TrimSpace(line[:idx])
		if strings.EqualFold(key, "location") {
			return strings.TrimSpace(line[idx+1:])
		}
	}
	return ""
}

type upnpRootXML struct {
	URLBase string        `xml:"URLBase"`
	Device  upnpDeviceXML `xml:"device"`
}

type upnpDeviceXML struct {
	DeviceType   string          `xml:"deviceType"`
	FriendlyName string          `xml:"friendlyName"`
	Manufacturer string          `xml:"manufacturer"`
	ModelName    string          `xml:"modelName"`
	UDN          string          `xml:"UDN"`
	Services     []upnpService   `xml:"serviceList>service"`
	Devices      []upnpDeviceXML `xml:"deviceList>device"`
}

type upnpService struct {
	ServiceType string `xml:"serviceType"`
	ControlURL  string `xml:"controlURL"`
}

func resolveUPnPURL(base *url.URL, raw string) string {
	ref, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return ""
	}
	return base.ResolveReference(ref).String()
}

func findDLNARenderer(ctx context.Context, dev upnpDeviceXML, base *url.URL, location string, allowLoopback bool) (DLNADevice, bool) {
	var avControl, rcControl string
	for _, svc := range dev.Services {
		st := strings.TrimSpace(svc.ServiceType)
		cu := strings.TrimSpace(svc.ControlURL)
		if cu == "" {
			continue
		}
		if strings.HasPrefix(st, "urn:schemas-upnp-org:service:AVTransport:") && avControl == "" {
			resolved := resolveUPnPURL(base, cu)
			if _, err := validateDLNAURL(ctx, resolved, allowLoopback); err == nil {
				avControl = resolved
			}
		} else if strings.HasPrefix(st, "urn:schemas-upnp-org:service:RenderingControl:") && rcControl == "" {
			resolved := resolveUPnPURL(base, cu)
			if _, err := validateDLNAURL(ctx, resolved, allowLoopback); err == nil {
				rcControl = resolved
			}
		}
	}
	if avControl != "" {
		udn := strings.TrimSpace(dev.UDN)
		if udn == "" {
			udn = location
		}
		name := strings.TrimSpace(dev.FriendlyName)
		if name == "" {
			name = location
		}
		return DLNADevice{
			UDN:                udn,
			Name:               name,
			Manufacturer:       strings.TrimSpace(dev.Manufacturer),
			Model:              strings.TrimSpace(dev.ModelName),
			Location:           location,
			AVTransportControl: avControl,
			RenderingControl:   rcControl,
		}, true
	}
	for _, child := range dev.Devices {
		if found, ok := findDLNARenderer(ctx, child, base, location, allowLoopback); ok {
			return found, true
		}
	}
	return DLNADevice{}, false
}

func parseUPnPDeviceXML(ctx context.Context, location string, body []byte, allowLoopback bool) (DLNADevice, error) {
	locURL, err := url.Parse(location)
	if err != nil {
		return DLNADevice{}, errors.New("DLNA 设备描述地址无效")
	}
	var root upnpRootXML
	if err := xml.Unmarshal(body, &root); err != nil {
		return DLNADevice{}, errors.New("无法解析 DLNA 设备描述")
	}
	base := locURL
	if rawBase := strings.TrimSpace(root.URLBase); rawBase != "" {
		if candidate, err := validateDLNAURL(ctx, rawBase, allowLoopback); err == nil {
			base = candidate
		}
	}
	dev, ok := findDLNARenderer(ctx, root.Device, base, location, allowLoopback)
	if !ok {
		return DLNADevice{}, errors.New("该设备未提供 AVTransport 音频投屏服务")
	}
	return dev, nil
}

func (m *dlnaManager) fetchDevice(ctx context.Context, location string, manual bool) (DLNADevice, error) {
	if _, err := validateDLNAURL(ctx, location, m.allowLoopback); err != nil {
		return DLNADevice{}, err
	}
	reqCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, location, nil)
	if err != nil {
		return DLNADevice{}, err
	}
	resp, err := m.httpClient.Do(req)
	if err != nil {
		return DLNADevice{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return DLNADevice{}, fmt.Errorf("DLNA device returned %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return DLNADevice{}, err
	}
	dev, err := parseUPnPDeviceXML(reqCtx, location, body, m.allowLoopback)
	if err != nil {
		return DLNADevice{}, err
	}
	dev.Manual = manual
	return dev, nil
}

func discoverSSDP(ctx context.Context, wait time.Duration) []string {
	if wait <= 0 {
		wait = 2 * time.Second
	}
	conn, err := net.ListenPacket("udp4", ":0")
	if err != nil {
		return nil
	}
	defer conn.Close()
	dst := &net.UDPAddr{IP: net.IPv4(239, 255, 255, 250), Port: 1900}
	for _, st := range []string{dlnaMediaRendererType, dlnaAVTransportService} {
		msg := fmt.Sprintf("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: %s\r\n\r\n", st)
		_, _ = conn.WriteTo([]byte(msg), dst)
	}
	deadline := time.Now().Add(wait)
	if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
		deadline = ctxDeadline
	}
	_ = conn.SetReadDeadline(deadline)
	seen := map[string]struct{}{}
	var out []string
	buf := make([]byte, 8192)
	for time.Now().Before(deadline) {
		n, _, err := conn.ReadFrom(buf)
		if err != nil {
			break
		}
		if loc := parseSSDPLocation(string(buf[:n])); loc != "" {
			if _, ok := seen[loc]; !ok {
				seen[loc] = struct{}{}
				out = append(out, loc)
			}
		}
	}
	return out
}

func (m *dlnaManager) discover(ctx context.Context, ssdpWait time.Duration) []DLNADevice {
	m.mu.Lock()
	manuals := append([]string(nil), m.settings.ManualLocations...)
	m.mu.Unlock()

	manualSet := map[string]bool{}
	var targets []string
	seen := map[string]bool{}
	for _, loc := range manuals {
		manualSet[loc] = true
		if !seen[loc] {
			seen[loc] = true
			targets = append(targets, loc)
		}
	}
	for _, loc := range discoverSSDP(ctx, ssdpWait) {
		if !seen[loc] {
			seen[loc] = true
			targets = append(targets, loc)
		}
	}

	var (
		wg  sync.WaitGroup
		mu  sync.Mutex
		sem = make(chan struct{}, 6)
	)
	found := map[string]DLNADevice{}
	for _, loc := range targets {
		wg.Add(1)
		go func(location string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			dev, err := m.fetchDevice(ctx, location, manualSet[location])
			if err != nil {
				return
			}
			mu.Lock()
			if existing, ok := found[dev.UDN]; !ok || (dev.Manual && !existing.Manual) {
				found[dev.UDN] = dev
			}
			mu.Unlock()
		}(loc)
	}
	wg.Wait()

	m.mu.Lock()
	m.devices = found
	m.scanned = true
	list := sortedDLNADevicesLocked(m.devices)
	m.mu.Unlock()
	return list
}

func sortedDLNADevicesLocked(devices map[string]DLNADevice) []DLNADevice {
	list := make([]DLNADevice, 0, len(devices))
	for _, d := range devices {
		list = append(list, d)
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].Name != list[j].Name {
			return list[i].Name < list[j].Name
		}
		return list[i].UDN < list[j].UDN
	})
	return list
}

func (m *dlnaManager) saveSettingsLocked() error {
	return atomicJSON(m.settingsPath, m.settings)
}

func xmlEscape(value string) string {
	var buf bytes.Buffer
	_ = xml.EscapeText(&buf, []byte(value))
	return buf.String()
}

func formatDLNADuration(seconds float64) string {
	if !math.IsNaN(seconds) && !math.IsInf(seconds, 0) && seconds > 0 {
		total := int(math.Round(seconds))
		return fmt.Sprintf("%d:%02d:%02d", total/3600, (total%3600)/60, total%60)
	}
	return "0:00:00"
}

func parseDLNADuration(raw string) float64 {
	raw = strings.TrimSpace(raw)
	if raw == "" || strings.EqualFold(raw, "NOT_IMPLEMENTED") {
		return 0
	}
	if dot := strings.IndexByte(raw, '.'); dot >= 0 {
		raw = raw[:dot]
	}
	parts := strings.Split(raw, ":")
	if len(parts) != 3 {
		return 0
	}
	h, err1 := strconv.Atoi(parts[0])
	m, err2 := strconv.Atoi(parts[1])
	s, err3 := strconv.Atoi(parts[2])
	if err1 != nil || err2 != nil || err3 != nil || h < 0 || m < 0 || s < 0 {
		return 0
	}
	return float64(h*3600 + m*60 + s)
}

func buildDIDLLite(track Track, mediaURL, coverURL, mimeType string) string {
	var b strings.Builder
	b.WriteString(`<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">`)
	b.WriteString(`<item id="` + xmlEscape(track.ID) + `" parentID="0" restricted="1">`)
	b.WriteString(`<dc:title>` + xmlEscape(track.Title) + `</dc:title>`)
	b.WriteString(`<dc:creator>` + xmlEscape(track.Artist) + `</dc:creator>`)
	b.WriteString(`<upnp:artist>` + xmlEscape(track.Artist) + `</upnp:artist>`)
	if track.Album != "" {
		b.WriteString(`<upnp:album>` + xmlEscape(track.Album) + `</upnp:album>`)
	}
	if coverURL != "" {
		b.WriteString(`<upnp:albumArtURI>` + xmlEscape(coverURL) + `</upnp:albumArtURI>`)
	}
	b.WriteString(`<res protocolInfo="http-get:*:` + xmlEscape(mimeType) + `:` + dlnaFeaturesFlags + `" duration="` + formatDLNADuration(track.Duration) + `">` + xmlEscape(mediaURL) + `</res>`)
	b.WriteString(`<upnp:class>object.item.audioItem.musicTrack</upnp:class>`)
	b.WriteString(`</item></DIDL-Lite>`)
	return b.String()
}

func (m *dlnaManager) soapRequest(ctx context.Context, controlURL, serviceType, action, innerXML string) ([]byte, error) {
	if _, err := validateDLNAURL(ctx, controlURL, m.allowLoopback); err != nil {
		return nil, err
	}
	envelope := fmt.Sprintf(`<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:%s xmlns:u="%s">%s</u:%s></s:Body></s:Envelope>`,
		action, serviceType, innerXML, action)
	reqCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, controlURL, strings.NewReader(envelope))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", `text/xml; charset="utf-8"`)
	req.Header.Set("SOAPAction", fmt.Sprintf(`"%s#%s"`, serviceType, action))
	resp, err := m.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		if msg := soapTag(body, "errorDescription"); msg != "" {
			return nil, fmt.Errorf("DLNA 错误：%s", msg)
		}
		if msg := soapTag(body, "faultstring"); msg != "" {
			return nil, fmt.Errorf("DLNA 错误：%s", msg)
		}
		return nil, fmt.Errorf("DLNA 返回状态 %d", resp.StatusCode)
	}
	return body, nil
}

func soapTag(body []byte, name string) string {
	dec := xml.NewDecoder(bytes.NewReader(body))
	for {
		tok, err := dec.Token()
		if err != nil {
			return ""
		}
		if se, ok := tok.(xml.StartElement); ok && strings.EqualFold(se.Name.Local, name) {
			var text string
			if err := dec.DecodeElement(&text, &se); err == nil {
				return strings.TrimSpace(text)
			}
		}
	}
}

func (m *dlnaManager) issueTicket(trackID string) (string, time.Time) {
	now := time.Now()
	expires := now.Add(dlnaTicketTTL)
	ticket := randomID(32)
	m.mu.Lock()
	defer m.mu.Unlock()
	for k, v := range m.tickets {
		if now.After(v.Expires) {
			delete(m.tickets, k)
		}
	}
	for len(m.tickets) >= dlnaTicketLimit {
		var oldestKey string
		var oldestCreated time.Time
		for k, v := range m.tickets {
			if oldestKey == "" || v.Created.Before(oldestCreated) {
				oldestKey = k
				oldestCreated = v.Created
			}
		}
		if oldestKey == "" {
			break
		}
		delete(m.tickets, oldestKey)
	}
	m.tickets[ticket] = dlnaTicket{TrackID: trackID, Expires: expires, Created: now}
	return ticket, expires
}

func (m *dlnaManager) lookupTicket(ticket string) (string, bool) {
	if len(ticket) != 64 {
		return "", false
	}
	now := time.Now()
	m.mu.Lock()
	defer m.mu.Unlock()
	entry, ok := m.tickets[ticket]
	if !ok || now.After(entry.Expires) {
		delete(m.tickets, ticket)
		return "", false
	}
	return entry.TrackID, true
}

func (m *dlnaManager) revokeAll() {
	m.mu.Lock()
	clear(m.tickets)
	m.mu.Unlock()
}

func detectLANIPv4() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, raw := range addrs {
			ipNet, ok := raw.(*net.IPNet)
			if !ok {
				continue
			}
			ip := ipNet.IP.To4()
			if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
				continue
			}
			return ip.String()
		}
	}
	return ""
}

func (m *dlnaManager) detectedBaseURL(r *http.Request) string {
	scheme := "http"
	if r != nil && (r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https")) {
		scheme = "https"
	}
	if r != nil && r.Host != "" {
		host := r.Host
		hostname := host
		if h, _, err := net.SplitHostPort(host); err == nil {
			hostname = h
		}
		addr, err := netip.ParseAddr(strings.Trim(hostname, "[]"))
		isLoop := err == nil && addr.IsLoopback() || strings.EqualFold(hostname, "localhost")
		if !isLoop {
			return scheme + "://" + host
		}
	}
	ip := detectLANIPv4()
	if ip != "" {
		port := "8080"
		if r != nil && r.Host != "" {
			if _, p, err := net.SplitHostPort(r.Host); err == nil && p != "" {
				port = p
			}
		} else if _, p, err := net.SplitHostPort(m.server.config.Addr); err == nil && p != "" {
			port = p
		}
		return "http://" + net.JoinHostPort(ip, port)
	}
	if r != nil && r.Host != "" {
		return scheme + "://" + r.Host
	}
	return ""
}

func (m *dlnaManager) resolveBaseURL(r *http.Request, requested string) (string, error) {
	if requested != "" {
		return normalizeDLNABaseURL(requested)
	}
	m.mu.Lock()
	saved := m.settings.BaseURL
	m.mu.Unlock()
	if saved != "" {
		return saved, nil
	}
	if m.server.config.DLNABaseURL != "" {
		return m.server.config.DLNABaseURL, nil
	}
	detected := m.detectedBaseURL(r)
	if detected == "" {
		return "", errors.New("无法确定 DLNA 设备可访问的服务地址，请在设置中填写回调地址")
	}
	return detected, nil
}

func (m *dlnaManager) snapshotStatus(ctx context.Context) DLNAStatus {
	m.mu.Lock()
	udn := m.activeUDN
	track := m.activeTrack
	dev, hasDev := m.devices[udn]
	m.mu.Unlock()
	if udn == "" || !hasDev {
		return DLNAStatus{Active: false}
	}
	status := DLNAStatus{
		Active:      true,
		DeviceUDN:   dev.UDN,
		DeviceName:  dev.Name,
		TrackID:     track.ID,
		TrackTitle:  track.Title,
		TrackArtist: track.Artist,
		Duration:    track.Duration,
	}
	if infoBody, err := m.soapRequest(ctx, dev.AVTransportControl, dlnaAVTransportService, "GetTransportInfo", `<InstanceID>0</InstanceID>`); err == nil {
		status.TransportState = soapTag(infoBody, "CurrentTransportState")
	} else {
		status.Error = err.Error()
	}
	if posBody, err := m.soapRequest(ctx, dev.AVTransportControl, dlnaAVTransportService, "GetPositionInfo", `<InstanceID>0</InstanceID>`); err == nil {
		if pos := parseDLNADuration(soapTag(posBody, "RelTime")); pos >= 0 {
			status.Position = pos
		}
		if dur := parseDLNADuration(soapTag(posBody, "TrackDuration")); dur > 0 {
			status.Duration = dur
		}
	}
	if dev.RenderingControl != "" {
		if volBody, err := m.soapRequest(ctx, dev.RenderingControl, dlnaRenderingControlService, "GetVolume", `<InstanceID>0</InstanceID><Channel>Master</Channel>`); err == nil {
			if vol, err := strconv.Atoi(soapTag(volBody, "CurrentVolume")); err == nil {
				status.Volume = vol
			}
		}
		if muteBody, err := m.soapRequest(ctx, dev.RenderingControl, dlnaRenderingControlService, "GetMute", `<InstanceID>0</InstanceID><Channel>Master</Channel>`); err == nil {
			mute := soapTag(muteBody, "CurrentMute")
			status.Muted = mute == "1" || strings.EqualFold(mute, "true")
		}
	}
	return status
}

func (s *Server) dlnaDevices(w http.ResponseWriter, r *http.Request) {
	refresh := r.URL.Query().Get("refresh") == "1"
	s.dlna.mu.Lock()
	scanned := s.dlna.scanned
	cached := sortedDLNADevicesLocked(s.dlna.devices)
	savedBase := s.dlna.settings.BaseURL
	s.dlna.mu.Unlock()
	if refresh || !scanned {
		cached = s.dlna.discover(r.Context(), 2*time.Second)
	}
	effective := savedBase
	if effective == "" {
		effective = s.config.DLNABaseURL
	}
	jsonResponse(w, 200, map[string]any{
		"items":             cached,
		"base_url":          effective,
		"detected_base_url": s.dlna.detectedBaseURL(r),
	})
}

func (s *Server) dlnaAddManual(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Location string `json:"location"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	body.Location = strings.TrimSpace(body.Location)
	if body.Location == "" {
		apiError(w, 400, "请输入 DLNA 设备描述地址")
		return
	}
	dev, err := s.dlna.fetchDevice(r.Context(), body.Location, true)
	if err != nil {
		apiError(w, 400, err.Error())
		return
	}
	s.dlna.mu.Lock()
	defer s.dlna.mu.Unlock()
	prev := s.dlna.settings.ManualLocations
	exists := false
	for _, item := range prev {
		if item == body.Location {
			exists = true
			break
		}
	}
	if !exists {
		s.dlna.settings.ManualLocations = append(s.dlna.settings.ManualLocations, body.Location)
		if err := s.dlna.saveSettingsLocked(); err != nil {
			s.dlna.settings.ManualLocations = prev
			apiError(w, 500, "无法保存 DLNA 设备设置")
			return
		}
	}
	s.dlna.devices[dev.UDN] = dev
	jsonResponse(w, 200, dev)
}

func (s *Server) dlnaRemoveManual(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Location string `json:"location"`
		UDN      string `json:"udn"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	location := strings.TrimSpace(body.Location)
	udn := strings.TrimSpace(body.UDN)
	if location == "" && udn == "" {
		apiError(w, 400, "请指定要移除的设备")
		return
	}
	s.dlna.mu.Lock()
	defer s.dlna.mu.Unlock()
	if location == "" && udn != "" {
		if dev, ok := s.dlna.devices[udn]; ok {
			location = dev.Location
		}
	}
	filtered := make([]string, 0, len(s.dlna.settings.ManualLocations))
	for _, item := range s.dlna.settings.ManualLocations {
		if item != location {
			filtered = append(filtered, item)
		}
	}
	prev := s.dlna.settings.ManualLocations
	s.dlna.settings.ManualLocations = filtered
	if err := s.dlna.saveSettingsLocked(); err != nil {
		s.dlna.settings.ManualLocations = prev
		apiError(w, 500, "无法更新 DLNA 设备设置")
		return
	}
	for k, dev := range s.dlna.devices {
		if (udn != "" && k == udn) || (location != "" && dev.Location == location) {
			delete(s.dlna.devices, k)
			if s.dlna.activeUDN == k {
				s.dlna.activeUDN = ""
				s.dlna.activeTrack = Track{}
			}
		}
	}
	jsonResponse(w, 200, map[string]bool{"ok": true})
}

func (s *Server) dlnaGetSettings(w http.ResponseWriter, r *http.Request) {
	s.dlna.mu.Lock()
	baseURL := s.dlna.settings.BaseURL
	manuals := append([]string(nil), s.dlna.settings.ManualLocations...)
	s.dlna.mu.Unlock()
	jsonResponse(w, 200, map[string]any{
		"base_url":          baseURL,
		"env_base_url":      s.config.DLNABaseURL,
		"detected_base_url": s.dlna.detectedBaseURL(r),
		"manual_locations":  manuals,
	})
}

func (s *Server) dlnaPutSettings(w http.ResponseWriter, r *http.Request) {
	var body struct {
		BaseURL string `json:"base_url"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	normalized, err := normalizeDLNABaseURL(body.BaseURL)
	if err != nil {
		apiError(w, 400, err.Error())
		return
	}
	s.dlna.mu.Lock()
	prev := s.dlna.settings.BaseURL
	s.dlna.settings.BaseURL = normalized
	if err := s.dlna.saveSettingsLocked(); err != nil {
		s.dlna.settings.BaseURL = prev
		s.dlna.mu.Unlock()
		apiError(w, 500, "无法保存 DLNA 设置")
		return
	}
	s.dlna.mu.Unlock()
	jsonResponse(w, 200, map[string]string{"base_url": normalized})
}

func (s *Server) dlnaStatusHandler(w http.ResponseWriter, r *http.Request) {
	jsonResponse(w, 200, s.dlna.snapshotStatus(r.Context()))
}

func (s *Server) dlnaPlayHandler(w http.ResponseWriter, r *http.Request) {
	var body struct {
		UDN      string  `json:"udn"`
		TrackID  string  `json:"track_id"`
		Position float64 `json:"position"`
		BaseURL  string  `json:"base_url"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	t, ok := s.store.Track(body.TrackID)
	if !ok {
		apiError(w, 404, "track not found")
		return
	}
	if t.Unavailable {
		apiError(w, 503, "歌曲暂不可用，请检查音源状态")
		return
	}
	s.dlna.mu.Lock()
	dev, hasDev := s.dlna.devices[body.UDN]
	s.dlna.mu.Unlock()
	if !hasDev {
		apiError(w, 404, "未找到指定的 DLNA 设备，请先刷新设备列表")
		return
	}
	baseURL, err := s.dlna.resolveBaseURL(r, body.BaseURL)
	if err != nil {
		apiError(w, 400, err.Error())
		return
	}
	ticket, _ := s.dlna.issueTicket(t.ID)
	mediaURL := baseURL + "/api/v1/dlna/media/" + ticket + "/" + url.PathEscape(trackFileName(t))
	coverURL := ""
	if t.Artwork != "" {
		coverURL = baseURL + "/api/v1/dlna/cover/" + ticket
	}
	metadata := buildDIDLLite(t, mediaURL, coverURL, trackMimeType(t.Format))
	setArgs := fmt.Sprintf(`<InstanceID>0</InstanceID><CurrentURI>%s</CurrentURI><CurrentURIMetaData>%s</CurrentURIMetaData>`,
		xmlEscape(mediaURL), xmlEscape(metadata))
	if _, err := s.dlna.soapRequest(r.Context(), dev.AVTransportControl, dlnaAVTransportService, "SetAVTransportURI", setArgs); err != nil {
		apiError(w, 502, err.Error())
		return
	}
	if body.Position > 1 {
		seekArgs := fmt.Sprintf(`<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>%s</Target>`, formatDLNADuration(body.Position))
		_, _ = s.dlna.soapRequest(r.Context(), dev.AVTransportControl, dlnaAVTransportService, "Seek", seekArgs)
	}
	if _, err := s.dlna.soapRequest(r.Context(), dev.AVTransportControl, dlnaAVTransportService, "Play", `<InstanceID>0</InstanceID><Speed>1</Speed>`); err != nil {
		apiError(w, 502, err.Error())
		return
	}
	s.dlna.mu.Lock()
	s.dlna.activeUDN = dev.UDN
	s.dlna.activeTrack = t
	s.dlna.mu.Unlock()
	jsonResponse(w, 200, s.dlna.snapshotStatus(r.Context()))
}

func (s *Server) dlnaControlHandler(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Action   string  `json:"action"`
		Position float64 `json:"position"`
		Volume   int     `json:"volume"`
		Muted    bool    `json:"muted"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	s.dlna.mu.Lock()
	dev, hasDev := s.dlna.devices[s.dlna.activeUDN]
	s.dlna.mu.Unlock()
	if !hasDev {
		apiError(w, 409, "当前没有活跃的 DLNA 投屏设备")
		return
	}
	var err error
	switch body.Action {
	case "play":
		_, err = s.dlna.soapRequest(r.Context(), dev.AVTransportControl, dlnaAVTransportService, "Play", `<InstanceID>0</InstanceID><Speed>1</Speed>`)
	case "pause":
		_, err = s.dlna.soapRequest(r.Context(), dev.AVTransportControl, dlnaAVTransportService, "Pause", `<InstanceID>0</InstanceID>`)
	case "stop":
		_, err = s.dlna.soapRequest(r.Context(), dev.AVTransportControl, dlnaAVTransportService, "Stop", `<InstanceID>0</InstanceID>`)
		if err == nil {
			s.dlna.mu.Lock()
			s.dlna.activeUDN = ""
			s.dlna.activeTrack = Track{}
			s.dlna.mu.Unlock()
			jsonResponse(w, 200, DLNAStatus{Active: false})
			return
		}
	case "seek":
		target := formatDLNADuration(body.Position)
		_, err = s.dlna.soapRequest(r.Context(), dev.AVTransportControl, dlnaAVTransportService, "Seek",
			fmt.Sprintf(`<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>%s</Target>`, target))
	case "volume":
		if dev.RenderingControl == "" {
			apiError(w, 400, "该 DLNA 设备不支持音量控制")
			return
		}
		vol := max(0, min(100, body.Volume))
		_, err = s.dlna.soapRequest(r.Context(), dev.RenderingControl, dlnaRenderingControlService, "SetVolume",
			fmt.Sprintf(`<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>%d</DesiredVolume>`, vol))
	case "mute":
		if dev.RenderingControl == "" {
			apiError(w, 400, "该 DLNA 设备不支持静音控制")
			return
		}
		muted := 0
		if body.Muted {
			muted = 1
		}
		_, err = s.dlna.soapRequest(r.Context(), dev.RenderingControl, dlnaRenderingControlService, "SetMute",
			fmt.Sprintf(`<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredMute>%d</DesiredMute>`, muted))
	default:
		apiError(w, 400, "unsupported DLNA control action")
		return
	}
	if err != nil {
		apiError(w, 502, err.Error())
		return
	}
	jsonResponse(w, 200, s.dlna.snapshotStatus(r.Context()))
}

func (s *Server) dlnaTicketHandler(w http.ResponseWriter, r *http.Request) {
	var body struct {
		TrackID string `json:"track_id"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	t, ok := s.store.Track(body.TrackID)
	if !ok {
		apiError(w, 404, "track not found")
		return
	}
	if t.Unavailable {
		apiError(w, 503, "歌曲暂不可用，请检查音源状态")
		return
	}
	ticket, expires := s.dlna.issueTicket(t.ID)
	coverPath := ""
	if t.Artwork != "" {
		coverPath = "/api/v1/dlna/cover/" + ticket
	}
	jsonResponse(w, 200, map[string]any{
		"ticket":     ticket,
		"media_path": "/api/v1/dlna/media/" + ticket + "/" + url.PathEscape(trackFileName(t)),
		"cover_path": coverPath,
		"mime":       trackMimeType(t.Format),
		"expires_at": expires.UTC().Format(time.RFC3339),
	})
}

func (s *Server) dlnaMedia(w http.ResponseWriter, r *http.Request) {
	trackID, ok := s.dlna.lookupTicket(r.PathValue("ticket"))
	if !ok {
		apiError(w, 404, "media ticket expired or invalid")
		return
	}
	w.Header().Set("transferMode.dlna.org", "Streaming")
	w.Header().Set("contentFeatures.dlna.org", dlnaFeaturesFlags)
	s.streamTrack(w, r, trackID)
}

func (s *Server) dlnaCover(w http.ResponseWriter, r *http.Request) {
	trackID, ok := s.dlna.lookupTicket(r.PathValue("ticket"))
	if !ok {
		http.NotFound(w, r)
		return
	}
	s.coverTrack(w, r, trackID)
}
