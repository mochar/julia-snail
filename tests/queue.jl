using Sockets
using Test
using JuliaSnail

const PORT = 6969
JuliaSnail.start(PORT)
client = connect(ip"127.0.0.1", PORT)

function send_req(sock, payload_str)
    println(sock, payload_str)
    flush(sock)
end

function read_resp(sock; timeout=2.0)
    task = @async readline(sock)
    res = timedwait(() -> istaskdone(task), timeout)
    res == :ok ? fetch(task) : nothing
end

@testset "JuliaSnail Server Queue & Concurrency Tests" begin
    @testset "Sequential FIFO execution with queue=true" begin
        send_req(client, "(ns = [:Main], reqid = \"init\", code = \"global test_log = Int[]\", origin = nothing, redirectio = false)")
        r = read_resp(client)
        @test occursin("julia-snail--response-success", r)

        send_req(client, "(ns = [:Main], reqid = \"q1\", code = \"sleep(0.2); push!(test_log, 1)\", origin = nothing, redirectio = false, queue = true)")
        send_req(client, "(ns = [:Main], reqid = \"q2\", code = \"sleep(0.1); push!(test_log, 2)\", origin = nothing, redirectio = false, queue = true)")
        send_req(client, "(ns = [:Main], reqid = \"q3\", code = \"push!(test_log, 3)\", origin = nothing, redirectio = false, queue = true)")

        res1 = read_resp(client)
        @test occursin("julia-snail--response-success", res1) && occursin("q1", res1)
        res2 = read_resp(client)
        @test occursin("julia-snail--response-success", res2) && occursin("q2", res2)
        res3 = read_resp(client)
        @test occursin("julia-snail--response-success", res3) && occursin("q3", res3)

        send_req(client, "(ns = [:Main], reqid = \"check1\", code = \"begin test_log end\", origin = nothing, redirectio = false)")
        r = read_resp(client)
        @test occursin("(1 2 3)", r) || occursin("[1, 2, 3]", r)
    end

    @testset "Failure cascading cancellation in queue" begin
        send_req(client, "(ns = [:Main], reqid = \"reset2\", code = \"global test_log2 = Int[]\", origin = nothing, redirectio = false)")
        read_resp(client)

        send_req(client, "(ns = [:Main], reqid = \"f1\", code = \"sleep(0.1); push!(test_log2, 1)\", origin = nothing, redirectio = false, queue = true)")
        send_req(client, "(ns = [:Main], reqid = \"f2\", code = \"sleep(0.1); error(\\\"test failure\\\")\", origin = nothing, redirectio = false, queue = true)")
        send_req(client, "(ns = [:Main], reqid = \"f3\", code = \"push!(test_log2, 3)\", origin = nothing, redirectio = false, queue = true)")
        send_req(client, "(ns = [:Main], reqid = \"f4\", code = \"push!(test_log2, 4)\", origin = nothing, redirectio = false, queue = true)")

        rf1 = read_resp(client)
        @test occursin("julia-snail--response-success", rf1) && occursin("f1", rf1)

        rf2 = read_resp(client)
        @test occursin("julia-snail--response-failure", rf2) && occursin("f2", rf2)

        rf3 = read_resp(client)
        @test occursin("julia-snail--response-failure", rf3) && occursin("f3", rf3) && occursin("canceled", lowercase(rf3))

        rf4 = read_resp(client)
        @test occursin("julia-snail--response-failure", rf4) && occursin("f4", rf4) && occursin("canceled", lowercase(rf4))

        send_req(client, "(ns = [:Main], reqid = \"check2\", code = \"begin test_log2 end\", origin = nothing, redirectio = false)")
        r = read_resp(client)
        @test occursin("(1)", r) || occursin("[1]", r)
    end

    @testset "Parallel execution with queue=false / default" begin
        send_req(client, "(ns = [:Main], reqid = \"p_slow\", code = \"sleep(0.4); 100\", origin = nothing, redirectio = false, queue = false)")
        send_req(client, "(ns = [:Main], reqid = \"p_fast\", code = \"begin 200 end\", origin = nothing, redirectio = false)")

        rp1 = read_resp(client)
        @test occursin("p_fast", rp1) && occursin("200", rp1)
        rp2 = read_resp(client)
        @test occursin("p_slow", rp2) && occursin("100", rp2)
    end

    @testset "Parallel request alongside active queue" begin
        send_req(client, "(ns = [:Main], reqid = \"q_slow\", code = \"sleep(0.4); :queued_done\", origin = nothing, redirectio = false, queue = true)")
        send_req(client, "(ns = [:Main], reqid = \"p_quick\", code = \"begin :parallel_done end\", origin = nothing, redirectio = false, queue = false)")

        rq1 = read_resp(client)
        @test occursin("p_quick", rq1)
        rq2 = read_resp(client)
        @test occursin("q_slow", rq2)
    end

    @testset "Interruption handling in queue" begin
        send_req(client, "(ns = [:Main], reqid = \"reset4\", code = \"global test_log4 = Int[]\", origin = nothing, redirectio = false)")
        read_resp(client)

        send_req(client, "(ns = [:Main], reqid = \"iq1\", code = \"sleep(2.0); push!(test_log4, 1)\", origin = nothing, redirectio = false, queue = true)")
        send_req(client, "(ns = [:Main], reqid = \"iq2\", code = \"push!(test_log4, 2)\", origin = nothing, redirectio = false, queue = true)")

        sleep(0.2)
        JuliaSnail.Tasks.interrupt("iq1")

        r1 = read_resp(client)
        @test occursin("julia-snail--response-interrupt", r1) && occursin("iq1", r1)

        r2 = read_resp(client)
        @test occursin("julia-snail--response-failure", r2) && occursin("iq2", r2) && occursin("canceled", lowercase(r2))

        send_req(client, "(ns = [:Main], reqid = \"check4\", code = \"begin test_log4 end\", origin = nothing, redirectio = false)")
        r = read_resp(client)
        @test occursin("nil", r) || occursin("Int64[]", r) || occursin("Int[]", r)
    end
end

isopen(client) && close(client)
JuliaSnail.stop()
