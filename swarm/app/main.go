package main

import (
	"log"
	"net/http"
	"os"
	"time"
)

func handler(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/" {
		http.ServeFile(w, r, "index.html")
		return
	}
	// Serve other static files
	http.ServeFile(w, r, r.URL.Path[1:])
}

func main() {
	// Set up file server
	fs := http.FileServer(http.Dir("."))
	http.HandleFunc("/", handler)

	// Get port from environment variable or use default 80
	port := os.Getenv("PORT")
	if port == "" {
		port = "80"
	}

	server := &http.Server{
		Addr:         ":" + port,
		Handler:      fs,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  15 * time.Second,
	}

	log.Printf("Starting server on :%s\n", port)
	log.Fatal(server.ListenAndServe())
}
