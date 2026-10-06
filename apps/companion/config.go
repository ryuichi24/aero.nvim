package main

import (
	"encoding/json"
	"errors"
	"flag"
	"io"
	"os"
)

func parseConfig(args []string) (config, error) {
	defaults := config{Bind: "127.0.0.1", Port: 8765, Origin: "http://localhost:8765"}
	c := defaults
	var settings string
	flags := flag.NewFlagSet("aero-companion", flag.ContinueOnError)
	flags.StringVar(&settings, "config", "", "JSON configuration exported by :Aero companion start")
	flags.StringVar(&c.Socket, "socket", "", "private Aero companion Unix socket (required without --config)")
	flags.StringVar(&c.Bind, "bind", defaults.Bind, "HTTP listen address; non-loopback requires HTTPS or --allow-http")
	flags.IntVar(&c.Port, "port", defaults.Port, "HTTP listen port")
	flags.StringVar(&c.Origin, "origin", defaults.Origin, "exact browser HTTP(S) origin")
	flags.StringVar(&c.Cert, "cert", "", "HTTPS certificate file")
	flags.StringVar(&c.Key, "key", "", "HTTPS private key file")
	flags.BoolVar(&c.AllowHTTP, "allow-http", false, "explicitly allow direct HTTP over a trusted private network")
	flags.StringVar(&c.DevicesFile, "devices-file", "", "private persistent device credential file")
	flags.BoolVar(&c.StdioControl, "stdio-control", false, "private parent-process control protocol (used by Neovim)")
	if err := flags.Parse(args); err != nil {
		return c, err
	}
	if flags.NArg() != 0 {
		return c, errors.New("unexpected positional arguments")
	}
	if settings != "" {
		file, err := os.Open(settings)
		if err != nil {
			return c, errors.New("could not open companion configuration")
		}
		defer file.Close()
		info, err := file.Stat()
		if err != nil || info.Size() > maxRequest {
			return c, errors.New("invalid or oversized companion configuration")
		}
		loaded := defaults
		decoder := json.NewDecoder(io.LimitReader(file, maxRequest))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&loaded); err != nil {
			return c, errors.New("invalid companion configuration")
		}
		if decoder.Decode(new(any)) != io.EOF {
			return c, errors.New("invalid companion configuration")
		}
		// Explicit CLI flags override setup-derived settings, including --allow-http=false.
		flags.Visit(func(f *flag.Flag) {
			switch f.Name {
			case "socket":
				loaded.Socket = c.Socket
			case "bind":
				loaded.Bind = c.Bind
			case "port":
				loaded.Port = c.Port
			case "origin":
				loaded.Origin = c.Origin
			case "cert":
				loaded.Cert = c.Cert
			case "key":
				loaded.Key = c.Key
			case "allow-http":
				loaded.AllowHTTP = c.AllowHTTP
			case "devices-file":
				loaded.DevicesFile = c.DevicesFile
			case "stdio-control":
				loaded.StdioControl = c.StdioControl
			}
		})
		c = loaded
	}
	if err := c.validate(); err != nil {
		return c, err
	}
	if c.DevicesFile == "" {
		var err error
		c.DevicesFile, err = defaultDevicesFile(c.Origin)
		if err != nil {
			return c, err
		}
	}
	return c, nil
}
