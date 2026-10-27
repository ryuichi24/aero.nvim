package main

// Device-cookie and pairing HTTP presentation; persistence is owned by state/deviceStore.
import (
	"crypto/sha256"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"
)

const deviceCookieAge = 365 * 24 * 60 * 60

func (b *bridge) cookie(token string, maxAge int) *http.Cookie {
	hash := sha256.Sum256([]byte(b.state.origin))

	cookie := &http.Cookie{
		Name: fmt.Sprintf("aero_device_%x", hash[:8]), Value: token, Path: "/", HttpOnly: true,
		SameSite: http.SameSiteStrictMode, Secure: strings.HasPrefix(b.state.origin, "https://"), MaxAge: maxAge,
	}
	if maxAge > 0 {
		cookie.Expires = time.Now().Add(time.Duration(maxAge) * time.Second)
	}

	return cookie
}

func (b *bridge) pair(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Code string  `json:"code"`
		Name *string `json:"name"`
	}
	if !decodeBody(w, r, &input) {
		return
	}

	name := "Phone"

	if input.Name != nil {
		name = *input.Name
	}

	token, device, err := b.state.pair(input.Code, name)
	if err != nil {
		if errors.Is(err, errPairingDenied) {
			reject(w, http.StatusUnauthorized, errPairingDenied.Error())
		} else {
			reject(w, http.StatusServiceUnavailable, "could not remember this device; pairing was not completed")
		}

		return
	}

	http.SetCookie(w, b.cookie(token, deviceCookieAge))
	reply(w, http.StatusOK, map[string]string{"device": device.ID})

	if b.onChange != nil {
		b.onChange("paired")
	}
}
