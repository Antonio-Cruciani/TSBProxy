using DataStructures
using StatsBase

struct BFS_ONBRA_data_structure
    sigma::Array{UInt128}
    dist::Array{Int64}
    sigma_t::Array{UInt128}
    sigma_z::Array{UInt128}
    dist_t::Array{Int64}
    predecessors::Array{Set{Tuple{Int64,Int64}}}
    boolean_matrix::Array{Bool}
    forward_queue::Queue{Tuple{Int64,Int64}}
    backward_queue::Queue{Tuple{Int64,Int64}}
    function BFS_ONBRA_data_structure(nn::Int64, ntn::Int64)
        return new(Array{UInt128}(undef, nn), Array{Int64}(undef, nn), Array{UInt128}(undef, ntn), zeros(Int64, ntn), Array{Int64}(undef, ntn), Array{Set{Tuple{Int64,Int64}}}(undef, ntn), falses(ntn), Queue{Tuple{Int64,Int64}}(), Queue{Tuple{Int64,Int64}}())
    end
end

function onbra_sample(tg::temporal_graph, sample_size::Int64)::Array{Tuple{Int64,Int64}}
    sample_pairs::Array{Tuple{Int64,Int64}} = []
    s::Int64 = 0
    z::Int64 = 0
    while length(sample_pairs) < sample_size
        s, z = sample(1:tg.num_nodes, 2, replace=false)
        push!(sample_pairs, (s, z))
    end
    return sample_pairs
end

function empirical_variance(tilde_b::Array{Float64}, sample_size::Int64, v::Int64)::Float64
    n::Int64 = div(length(tilde_b), sample_size)
    variance::Float64 = 0
    for i in 1:sample_size
        for j in (i+1):sample_size
            variance += (((tilde_b[(i-1)*n+v] - tilde_b[(j-1)*n+v]) / sample_size)^2)
        end
    end
    return variance / (sample_size * (sample_size - 1))
end

function theoretical_error_bound(tilde_b::Array{Float64}, sample_size::Int64, eta::Float64)::Float64
    n::Int64 = div(length(tilde_b), sample_size)
    error::Float64 = 0.0
    max_error::Float64 = 0.0
    for u in 1:n
        variance::Float64 = empirical_variance(tilde_b, sample_size, u)
        error = sqrt(2 * variance * log(4 * n / eta) / sample_size) + 7 * log(4 * n / eta) / (3 * (sample_size - 1))
        if (error > max_error)
            max_error = error
        end
    end
    return max_error
end

function onbra(tg::temporal_graph, sample_size::Int64, verbose_step::Int64; test_sample=Array{Tuple{Int64,Int64}}[])::Tuple{Array{Float64},Array{Float64}}
    start_time = time()
    sample = test_sample
    if (length(sample) == 0 || length(sample) != sample_size)
        sample::Array{Tuple{Int64,Int64}} = onbra_sample(tg, sample_size)
    end
    tal::Array{Array{Tuple{Int64,Int64}}} = temporal_adjacency_list(tg)
    tn_index::Dict{Tuple{Int64,Int64},Int64} = temporal_node_index(tg)
    bfs_ds::BFS_ONBRA_data_structure = BFS_ONBRA_data_structure(tg.num_nodes, length(keys(tn_index)))
    tilde_b::Array{Float64} = zeros(sample_size * tg.num_nodes)
    u::Int64 = -1
    w::Int64 = -1
    t::Int64 = -1
    t_w::Int64 = -1
    tni::Int64 = -1
    tni_w::Int64 = -1
    temporal_node::Tuple{Int64,Int64} = (-1, -1)
    processed_so_far::Int64 = 0
    exec_time::Array{Float64} = zeros(sample_size)
    for i in 1:sample_size
        exec_time[i] = time()
        s = sample[i][1]
        z = sample[i][2]
        for u in 1:tg.num_nodes
            bfs_ds.dist[u] = -1
            bfs_ds.sigma[u] = 0
        end
        for tn in 1:lastindex(bfs_ds.dist_t)
            bfs_ds.sigma_t[tn] = 0
            bfs_ds.dist_t[tn] = -1
            bfs_ds.predecessors[tn] = Set{Tuple{Int64,Int64}}()
        end
        tni = tn_index[(s, 0)]
        bfs_ds.sigma[s] = 1
        bfs_ds.sigma_t[tni] = 1
        bfs_ds.dist[s] = 0
        bfs_ds.dist_t[tni] = 0
        enqueue!(bfs_ds.forward_queue, (s, 0))
        d_z_min = Inf
        while length(bfs_ds.forward_queue) != 0
            temporal_node = dequeue!(bfs_ds.forward_queue)
            u = temporal_node[1]
            t = temporal_node[2]
            tni = tn_index[(u, t)]
            if bfs_ds.dist_t[tni] < d_z_min
                for neig in next_temporal_neighbors(tal, u, t)
                    w = neig[1]
                    t_w = neig[2]
                    tni_w = tn_index[(w, t_w)]
                    if bfs_ds.dist_t[tni_w] == -1
                        bfs_ds.dist_t[tni_w] = bfs_ds.dist_t[tni] + 1
                        if bfs_ds.dist[w] == -1
                            bfs_ds.dist[w] = bfs_ds.dist_t[tni] + 1
                            if w == z
                                d_z_min = bfs_ds.dist[w]
                            end
                        end
                        enqueue!(bfs_ds.forward_queue, neig)
                    end
                    if bfs_ds.dist_t[tni_w] == bfs_ds.dist_t[tni] + 1
                        if (bfs_ds.sigma_t[tni] > typemax(UInt128) - bfs_ds.sigma_t[tni_w])
                            println("Overflow occurred with source ", s)
                            return [], 0.0
                        end
                        bfs_ds.sigma_t[tni_w] += bfs_ds.sigma_t[tni]
                        push!(bfs_ds.predecessors[tni_w], temporal_node)
                        if bfs_ds.dist_t[tni_w] == bfs_ds.dist[w]
                            if (bfs_ds.sigma_t[tni] > typemax(UInt128) - bfs_ds.sigma[w])
                                println("Overflow occurred with source ", s)
                                return [], 0.0
                            end
                            bfs_ds.sigma[w] += bfs_ds.sigma_t[tni]
                        end
                    end
                end
            end
        end
        if bfs_ds.dist[z] > 0
            for tn in 1:lastindex(bfs_ds.dist_t)
                bfs_ds.sigma_z[tn] = 0
                bfs_ds.boolean_matrix[tn] = false
            end
            tni = tn_index[(s, 0)]
            bfs_ds.sigma_z[tni] = 1
        end
        for t in 1:lastindex(tg.file_time)
            tni = get(tn_index, (z, t), 0)
            if tni > 0 && bfs_ds.sigma_t[tni] > 0
                for pred in bfs_ds.predecessors[tni]
                    tni_w = tn_index[(pred[1], pred[2])]
                    bfs_ds.sigma_z[tni_w] += 1
                    if !bfs_ds.boolean_matrix[tni_w]
                        enqueue!(bfs_ds.backward_queue, pred)
                        bfs_ds.boolean_matrix[tni_w] = true
                    end
                end
            end
        end
        while length(bfs_ds.backward_queue) > 0
            temporal_node = dequeue!(bfs_ds.backward_queue)
            tni = tn_index[(temporal_node[1], temporal_node[2])]
            if temporal_node[1] != s
                tilde_b[(i-1)*tg.num_nodes+temporal_node[1]] += (bfs_ds.sigma_z[tni] * (bfs_ds.sigma_t[tni] / bfs_ds.sigma[z]))
                for pred in bfs_ds.predecessors[tni]
                    tni_w = tn_index[(pred[1], pred[2])]
                    bfs_ds.sigma_z[tni_w] += bfs_ds.sigma_z[tni]
                    if !bfs_ds.boolean_matrix[tni_w]
                        enqueue!(bfs_ds.backward_queue, pred)
                        bfs_ds.boolean_matrix[tni_w] = true
                    end
                end
            end
        end
        exec_time[i] = time() - exec_time[i]
        processed_so_far = processed_so_far + 1
        if (verbose_step > 0 && processed_so_far % verbose_step == 0)
            finish_partial::String = string(round(time() - start_time; digits=4))
            println("Processed " * string(processed_so_far) * "/" * string(sample_size) * " pairs in " * finish_partial * " seconds")
        end
    end
    finish_total::Float64 = round(time() - start_time; digits=4)
    return tilde_b, exec_time
end

# function onbra(tg::temporal_graph, sample_size::Int64, epsilon::Float64, eta::Float64, verbose_step::Int64)
#     global_sample_size::Int64 = sample_size
#     tilde_b::Array{Float64}, global_t::Float64 = onbra_sample(tg, sample_size, 0)
#     error_bound::Float64 = theoretical_error_bound(tilde_b, global_sample_size, eta)
#     println("Error bound " * string(error_bound) * " with sample size " * string(global_sample_size) * " (time " * string(global_t) * ")")
#     t_b::Array{Float64} = []
#     t::Float64 = 0.0
#     while (error_bound > epsilon)
#         t_b, t = onbra_sample(tg, sample_size, 0)
#         append!(tilde_b, t_b)
#         global_t += t
#         global_sample_size += sample_size
#         error_bound = theoretical_error_bound(tilde_b, global_sample_size, eta)
#         println("Error bound " * string(error_bound) * " with sample size " * string(global_sample_size) * " (time " * string(global_t) * ")")
#     end
#     return tilde_b, global_t
# end

function onbra_avg_time(tg::temporal_graph, sample_size::Int64)
    _, exec_time = onbra(tg, sample_size, 0)
    println("Average ONBRA execution time: " * string(mean(exec_time)) * " (" * string(std(exec_time)) * ")")
end
