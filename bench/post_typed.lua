-- bench/post_typed.lua -- wrk POST workload for Honk POST /api/typed.
-- Exercises typed json::Reader binding: nested object, array, numbers,
-- unknown-key skip. Same body every request (static benchmark payload).
wrk.method = "POST"
wrk.headers["Content-Type"] = "application/json"
wrk.body = '{"name":"wrk bench user","age":30,"score":9.5,"tags":["alpha","beta","gamma"],"address":{"city":"Springfield","zip":12345},"extra":{"x":[1,2,3]}}'
