package resona

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"math/big"
	"net/http"
	"slices"
	"strings"
	"testing"
)

func cloudTestCipher(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 1024)
	if err != nil {
		t.Fatal(err)
	}
	original := cloudRSAKey
	cloudRSAKey = &key.PublicKey
	t.Cleanup(func() { cloudRSAKey = original })
	return key
}

func cloudSignedResponse(t *testing.T, key *rsa.PrivateKey, data []byte) string {
	t.Helper()
	data = bytes.Clone(data)
	cloudXOR(data, []byte{0x8d, 0xa5, 0xa5, 0x8d})
	slices.Reverse(data)
	seed := bytes.Repeat([]byte{0x11}, 16)
	cloudXOR(data, cloudResponseKey(seed))
	data = append(seed, data...)
	var cipher []byte
	for len(data) > 0 {
		n := min(len(data), key.Size()-11)
		block := bytes.Repeat([]byte{0xff}, key.Size())
		block[0], block[1], block[len(block)-n-1] = 0, 1, 0
		copy(block[len(block)-n:], data[:n])
		cipher = append(cipher, new(big.Int).Exp(new(big.Int).SetBytes(block), key.D, key.N).FillBytes(make([]byte, key.Size()))...)
		data = data[n:]
	}
	return base64.StdEncoding.EncodeToString(cipher)
}

func cloudDownloadResponse(t *testing.T, w http.ResponseWriter, r *http.Request, key *rsa.PrivateKey, id, link string) {
	t.Helper()
	if (r.URL.Path != "/app/chrome/downurl" && r.URL.Path != "/android/2.0/ufile/download") ||
		r.Method != "POST" || r.UserAgent() == "" ||
		r.Header.Get("Authorization") != "" || !strings.Contains(r.Header.Get("Cookie"), "UID=42_A1") {
		t.Error("wrong Cookie download request")
	}
	_ = r.ParseForm()
	cipher, err := base64.StdEncoding.DecodeString(r.Form.Get("data"))
	if err != nil || len(cipher) == 0 || len(cipher)%key.Size() != 0 {
		t.Error("invalid request ciphertext")
		w.WriteHeader(400)
		return
	}
	var plain []byte
	for len(cipher) > 0 {
		block, err := rsa.DecryptPKCS1v15(rand.Reader, key, cipher[:key.Size()])
		if err != nil {
			t.Error(err)
			w.WriteHeader(400)
			return
		}
		plain = append(plain, block...)
		cipher = cipher[key.Size():]
	}
	if len(plain) < 16 || !bytes.Equal(plain[:16], make([]byte, 16)) {
		t.Error("missing request key")
		w.WriteHeader(400)
		return
	}
	plain = plain[16:]
	cloudXOR(plain, []byte{0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18, 0x4c, 0x01, 0x3f, 0x46})
	slices.Reverse(plain)
	cloudXOR(plain, []byte{0x8d, 0xa5, 0xa5, 0x8d})
	var request map[string]string
	field := "pickcode"
	if r.URL.Path == "/android/2.0/ufile/download" {
		field = "pick_code"
		if r.URL.RawQuery != "" {
			t.Error("Android download request must not add query parameters")
		}
	} else if r.URL.Query().Get("t") == "" {
		t.Error("Chrome download request is missing timestamp")
	}
	if json.Unmarshal(plain, &request) != nil || request[field] != "abcdefghijklmnopq" || len(request) != 1 {
		t.Error("invalid encrypted download payload")
	}
	data, _ := json.Marshal(map[string]any{id: map[string]any{"url": map[string]string{"url": link}}})
	cloudResponse(w, cloudSignedResponse(t, key, data))
}

func TestCloudCipherFramesAndMalformedResponses(t *testing.T) {
	key := cloudTestCipher(t)
	for _, plain := range []string{"x", "a song", strings.Repeat("a", 1000)} {
		value := cloudSignedResponse(t, key, []byte(plain))
		decoded, err := cloudDecrypt(value)
		if err != nil || string(decoded) != plain {
			t.Fatalf("decode: %s %v", decoded, err)
		}
	}
	for _, value := range []string{"", "not base64", "AAAA", base64.StdEncoding.EncodeToString(make([]byte, key.Size())), base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0xff}, key.Size()))} {
		if _, err := cloudDecrypt(value); err == nil {
			t.Fatal("malformed response accepted")
		}
	}
	// Independent p115cipher vectors cover the non-aligned XOR prefix and key schedule.
	x := []byte("hello-115")
	cloudXOR(x, []byte{0x8d, 0xa5, 0xa5, 0x8d})
	if hex.EncodeToString(x) != "e5e8c9c9e2a09494b8" {
		t.Fatalf("XOR protocol mismatch: %x", x)
	}
	if hex.EncodeToString(cloudResponseKey(make([]byte, 16))) != "ac822114c15858c1142182ac" {
		t.Fatalf("key schedule mismatch: %x", cloudResponseKey(make([]byte, 16)))
	}
}
