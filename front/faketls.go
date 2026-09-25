package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"net"
	"time"
)

const (
	fakeTLSDigestPos = 11
	fakeTLSDigestLen = 32
	fakeTLSMaxRecord = 16384
)

var fakeTLSPrefix = []byte{0x16, 0x03, 0x01}

func fakeTLSMatches(packet, secret []byte) bool {
	if len(secret) != 16 || len(packet) < fakeTLSDigestPos+fakeTLSDigestLen {
		return false
	}
	if !bytes.Equal(packet[:3], fakeTLSPrefix) {
		return false
	}
	recordLen := int(binary.BigEndian.Uint16(packet[3:5]))
	if recordLen < fakeTLSDigestPos+fakeTLSDigestLen-5 || recordLen > fakeTLSMaxRecord || len(packet) < 5+recordLen {
		return false
	}
	record := packet[:5+recordLen]
	msg := bytes.Clone(record)
	copy(msg[fakeTLSDigestPos:fakeTLSDigestPos+fakeTLSDigestLen], make([]byte, fakeTLSDigestLen))
	mac := hmac.New(sha256.New, secret)
	mac.Write(msg)
	computed := mac.Sum(nil)
	digest := record[fakeTLSDigestPos : fakeTLSDigestPos+fakeTLSDigestLen]
	for i := 0; i < fakeTLSDigestLen-4; i++ {
		if digest[i]^computed[i] != 0 {
			return false
		}
	}
	return true
}

func readClientHello(conn net.Conn) []byte {
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	defer conn.SetReadDeadline(time.Time{})
	buf := make([]byte, 0, 512)
	tmp := make([]byte, 1024)
	need := 5
	for len(buf) < need && len(buf) < 5+fakeTLSMaxRecord {
		n, err := conn.Read(tmp)
		if n > 0 {
			buf = append(buf, tmp[:n]...)
			if need == 5 && len(buf) >= 5 {
				if !bytes.Equal(buf[:3], fakeTLSPrefix) {
					return buf
				}
				recordLen := int(binary.BigEndian.Uint16(buf[3:5]))
				if recordLen < fakeTLSDigestPos+fakeTLSDigestLen-5 || recordLen > fakeTLSMaxRecord {
					return buf
				}
				need = 5 + recordLen
			}
		}
		if err != nil {
			return buf
		}
	}
	return buf
}
