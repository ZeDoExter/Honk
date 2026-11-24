// Go stdlib contender: net/http ServeMux, encoding/json, GOMAXPROCS=1.
package main

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
)

func plaintext(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	w.Write([]byte("Hello, World!"))
}

func jsonMsg(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	b, _ := json.Marshal(map[string]string{"message": "Hello, World!"})
	w.Write(b)
}

func frameBench(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Frame-Bench", "1")
		next(w, r)
	}
}

func getUser(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	role := r.URL.Query().Get("role")
	w.Header().Set("Content-Type", "application/json")
	b, _ := json.Marshal(map[string]string{"id": id, "role": role})
	w.Write(b)
}

type createReq struct {
	Name   *string `json:"name"`
	Age    *int64  `json:"age"`
	Active *bool   `json:"active"`
}

func badRequest(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusBadRequest)
	w.Write([]byte("Bad Request"))
}

func createUser(w http.ResponseWriter, r *http.Request) {
	// 1 MiB cap like Honk (Honk answers 413 here; Go answers 400 — untested path).
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		badRequest(w)
		return
	}
	var req createReq
	// Unmarshal rejects malformed JSON and trailing garbage after the value.
	if err := json.Unmarshal(body, &req); err != nil {
		badRequest(w)
		return
	}
	if req.Name == nil || *req.Name == "" || req.Age == nil || req.Active == nil {
		badRequest(w)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	b, _ := json.Marshal(map[string]any{"created": true, "name": *req.Name, "age": *req.Age})
	w.Write(b)
}

func main() {
	port := "18504"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /plaintext", plaintext)
	mux.HandleFunc("GET /json", jsonMsg)
	mux.HandleFunc("GET /users/{id}", frameBench(getUser))
	mux.HandleFunc("POST /users", createUser)
	println("go-std listening on " + port)
	srv := &http.Server{Addr: "127.0.0.1:" + port, Handler: mux}
	srv.ListenAndServe()
}
