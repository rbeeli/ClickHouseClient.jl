function test_streaming_queries(sock)
    @testset "Streaming query cancellation" begin
        ch = select_channel(sock, "SELECT number FROM numbers(100000000)"; csize = 1)
        @test take!(ch) isa QueryBlock
        close(ch)
        for _ in 1:50
            !is_busy(sock) && break
            sleep(0.05)
        end
        @test !is_busy(sock)
    end
end
