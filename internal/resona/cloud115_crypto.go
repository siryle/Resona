package resona

// 115 RSA/XOR framing adapted from ChenyangGao/p115client's p115cipher (GPL-3.0).
// The public-key response operation is a protocol requirement, not secret storage.
import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"errors"
	"math/big"
	"slices"
)

var cloudRSAKey = func() *rsa.PublicKey {
	n, _ := new(big.Int).SetString("8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b8602136477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad6338c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f10a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683", 16)
	return &rsa.PublicKey{N: n, E: 65537}
}()

var cloudXORSeed = [...]byte{
	0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a, 0x1a, 0x45, 0xe8, 0xbe, 0x7d, 0xa6, 0x73, 0xb8,
	0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4, 0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa,
	0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86, 0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
	0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd, 0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7,
	0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e, 0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86,
	0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34, 0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
	0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59, 0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48,
	0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77, 0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e,
	0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b, 0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5,
}

func cloudXOR(data, key []byte) {
	mod := len(data) % 4
	for i := range data {
		k := i
		if i >= mod {
			k -= mod
		}
		data[i] ^= key[k%len(key)]
	}
}

func cloudResponseKey(seed []byte) []byte {
	key := make([]byte, 12)
	for i := range key {
		key[i] = (seed[i] + cloudXORSeed[12*i]) ^ cloudXORSeed[12*(11-i)]
	}
	return key
}

func cloudEncrypt(data []byte) (string, error) {
	data = bytes.Clone(data)
	cloudXOR(data, []byte{0x8d, 0xa5, 0xa5, 0x8d})
	slices.Reverse(data)
	cloudXOR(data, []byte{0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18, 0x4c, 0x01, 0x3f, 0x46})
	data = append(make([]byte, 16), data...)
	var encrypted []byte
	for len(data) > 0 {
		n := min(len(data), cloudRSAKey.Size()-11)
		block, err := rsa.EncryptPKCS1v15(rand.Reader, cloudRSAKey, data[:n])
		if err != nil {
			return "", err
		}
		encrypted = append(encrypted, block...)
		data = data[n:]
	}
	return base64.StdEncoding.EncodeToString(encrypted), nil
}

func cloudDecrypt(value string) ([]byte, error) {
	invalid := errors.New("invalid 115 RSA response")
	data, err := base64.StdEncoding.DecodeString(value)
	size := cloudRSAKey.Size()
	if err != nil || len(data) == 0 || len(data)%size != 0 {
		return nil, invalid
	}
	var plain []byte
	for len(data) > 0 {
		cipher := new(big.Int).SetBytes(data[:size])
		if cipher.Cmp(cloudRSAKey.N) >= 0 {
			return nil, invalid
		}
		block := new(big.Int).Exp(cipher, big.NewInt(int64(cloudRSAKey.E)), cloudRSAKey.N).FillBytes(make([]byte, size))
		if block[0] != 0 || (block[1] != 1 && block[1] != 2) {
			return nil, invalid
		}
		delimiter := bytes.IndexByte(block[2:], 0) + 2
		if delimiter < 10 {
			return nil, invalid
		}
		if block[1] == 1 && !bytes.Equal(block[2:delimiter], bytes.Repeat([]byte{0xff}, delimiter-2)) {
			return nil, invalid
		}
		plain = append(plain, block[delimiter+1:]...)
		data = data[size:]
	}
	if len(plain) < 16 {
		return nil, invalid
	}
	key := cloudResponseKey(plain[:16])
	plain = plain[16:]
	cloudXOR(plain, key)
	slices.Reverse(plain)
	cloudXOR(plain, []byte{0x8d, 0xa5, 0xa5, 0x8d})
	return plain, nil
}
