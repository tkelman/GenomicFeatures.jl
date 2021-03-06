# BigBed Overlap
# ==============

immutable OverlapIterator
    reader::Reader
    chromid::UInt32
    chromstart::UInt32
    chromend::UInt32
end

function Base.eltype(::Type{OverlapIterator})
    return Record
end

function Base.iteratorsize(::Type{OverlapIterator})
    return Base.SizeUnknown()
end

function GenomicFeatures.eachoverlap(reader::Reader, interval::GenomicFeatures.Interval)
    if haskey(reader.chroms, interval.seqname)
        id, _ = reader.chroms[interval.seqname]
    else
        id = typemax(UInt32)
    end
    return OverlapIterator(reader, id, interval.first - 1, interval.last)
end

type OverlapIteratorState
    state::BioCore.Ragel.State
    data::Vector{UInt8}
    done::Bool
    record::Record
    blocks::Vector{BBI.Block}
    current_block::Int
end

function Base.start(iter::OverlapIterator)
    data = Vector{UInt8}(iter.reader.header.uncompress_buf_size)
    blocks = BBI.find_overlapping_blocks(iter.reader.index, iter.chromid, iter.chromstart, iter.chromend)
    if !isempty(blocks)
        seek(iter.reader.stream, blocks[1].offset)
    end
    return OverlapIteratorState(
        BioCore.Ragel.State(
            data_machine.start_state,
            Libz.ZlibInflateInputStream(iter.reader.stream, reset_on_end=false)),
        data,
        isempty(blocks), Record(), blocks, isempty(blocks) ? 1 : 2)
end

function Base.done(iter::OverlapIterator, state::OverlapIteratorState)
    advance!(iter, state)
    return state.done
end

function Base.next(iter::OverlapIterator, state::OverlapIteratorState)
    return copy(state.record), state
end

function advance!(iter::OverlapIterator, state::OverlapIteratorState)
    while true
        while state.current_block ≤ endof(state.blocks) && eof(state.state.stream)
            block = state.blocks[state.current_block]
            seek(iter.reader.stream, block.offset)
            size = BBI.uncompress!(state.data, read(iter.reader.stream, block.size))
            state.state = BioCore.Ragel.State(data_machine.start_state, BufferedStreams.BufferedInputStream(state.data[1:size]))
            state.current_block += 1
        end
        if state.done || (state.current_block > endof(state.blocks) && eof(state.state.stream))
            state.done = true
            return state
        end

        _read!(iter.reader, state.state, state.record)
        state.record.reader = iter.reader
        if overlaps(state.record, iter.chromid, iter.chromstart, iter.chromend)
            return state
        end
    end
end

function overlaps(record::Record, chromid::UInt32, chromstart::UInt32, chromend::UInt32)
    return record.chromid == chromid && !(record.chromend ≤ chromstart || record.chromstart ≥ chromend)
end
