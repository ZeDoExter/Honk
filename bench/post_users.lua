-- bench/post_users.lua -- wrk POST workload for the cross-framework shootout (Workload 4).
-- Fixed valid body; every contender must answer 201.
wrk.method = "POST"
wrk.headers["Content-Type"] = "application/json"
wrk.body = '{"name":"alice","age":30,"active":true}'
