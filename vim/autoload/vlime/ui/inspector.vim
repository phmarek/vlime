function! vlime#ui#inspector#InitInspectorBuf(ui, conn, thread)
    let buf = bufnr(vlime#ui#InspectorBufName(a:conn), v:true)
    if !vlime#ui#VlimeBufferInitialized(buf)
        call vlime#ui#SetVlimeBufferOpts(buf, a:conn)
        call vlime#ui#WithBuffer(buf, function('s:InitInspectorBuf'))
    endif
    if type(a:thread) != v:t_none
        call a:ui.SetCurrentThread(a:thread, buf)
    endif
    return buf
endfunction

function! vlime#ui#inspector#FillInspectorBuf(content, thread, itag)
    let b:vlime_inspector_title = a:content['TITLE']
    let b:vlime_inspector_content_start = a:content['CONTENT'][2]
    let b:vlime_inspector_content_end = a:content['CONTENT'][3]
    let b:vlime_inspector_content_more =
                \ a:content['CONTENT'][1] > b:vlime_inspector_content_end

    setlocal modifiable

    call vlime#ui#ReplaceContent(a:content['TITLE'] . "\n"
                \ . repeat('=', len(a:content['TITLE'])) . "\n\n")
    normal! G$

    let coords = []
    call vlime#ui#inspector#FillInspectorBufContent(
                \ a:content['CONTENT'][0], coords)

    let range_buttons = []
    if b:vlime_inspector_content_start > 0
        call add(range_buttons,
                    \ [{'name': 'RANGE', 'package': 'KEYWORD'},
                        \ "[prev range]", -1])
    endif
    if b:vlime_inspector_content_more
        if len(range_buttons) > 0
            call add(range_buttons, '  ')
        endif
        call add(range_buttons,
                    \ [{'name': 'RANGE', 'package': 'KEYWORD'},
                        \ "[next range]", 1])
    endif
    if len(range_buttons) > 0
        call add(range_buttons, '  ')
        call add(range_buttons,
                    \ [{'name': 'RANGE', 'package': 'KEYWORD'},
                        \ "[all content]", 0])
        if len(getline('.')) > 0
            let range_buttons = ["\n", range_buttons]
        endif
        call vlime#ui#inspector#FillInspectorBufContent(range_buttons, coords)
    endif

    setlocal nomodifiable

    let b:vlime_inspector_coords = coords

    augroup InspectorLeaveAu
        autocmd!
        execute 'autocmd BufWinLeave <buffer> call vlime#ui#inspector#ResetInspectorBuffer('
                    \ . bufnr('%') . ')'
        if type(a:thread) != v:t_none && type(a:itag) != v:t_none
            execute 'autocmd BufWinLeave <buffer> call b:vlime_conn.Return('
                        \ . a:thread . ', ' . a:itag . ', v:null)'
        endif
    augroup end
endfunction

function! vlime#ui#inspector#FillInspectorBufContent(content, coords)
    if type(a:content) == v:t_string
        call vlime#ui#AppendString(a:content)
        normal! G$
    elseif type(a:content) == v:t_list
        if len(a:content) == 3 && type(a:content[0]) == v:t_dict
            let begin_pos = getcurpos()
            if begin_pos[2] != 1 || len(getline('.')) > 0
                let begin_pos[2] += 1
            endif
            call vlime#ui#inspector#FillInspectorBufContent(
                        \ a:content[1], a:coords)
            let end_pos = getcurpos()
            call add(a:coords, {
                        \ 'begin': [begin_pos[1], begin_pos[2]],
                        \ 'end': [end_pos[1], end_pos[2]],
                        \ 'type': a:content[0]['name'],
                        \ 'id': a:content[2],
                        \ })
        else
            for c in a:content
                call vlime#ui#inspector#FillInspectorBufContent(c, a:coords)
            endfor
        endif
    endif
endfunction

function! vlime#ui#inspector#ResetInspectorBuffer(bufnr)
    call setbufvar(a:bufnr, 'vlime_conn', v:null)
    call setbufvar(a:bufnr, 'vlime_inspector_coords', [])
    execute 'bunload! ' . a:bufnr
endfunction

function! vlime#ui#inspector#InspectorSelect()
    let cur_pos = getcurpos()
    let coord = v:null
    for c in b:vlime_inspector_coords
        if vlime#ui#MatchCoord(c, cur_pos[1], cur_pos[2])
            let coord = c
            break
        endif
    endfor

    if type(coord) == v:t_none
        return
    endif

    if coord['type'] == 'ACTION'
        call b:vlime_conn.InspectorCallNthAction(coord['id'],
                    \ {c, r -> c.ui.OnInspect(c, r, v:null, v:null)})
    elseif coord['type'] == 'VALUE'
        call b:vlime_conn.InspectNthPart(coord['id'],
                    \ {c, r -> c.ui.OnInspect(c, r, v:null, v:null)})
    elseif coord['type'] == 'RANGE'
        let range_size = b:vlime_inspector_content_end -
                    \ b:vlime_inspector_content_start
        if coord['id'] > 0
            let next_start = b:vlime_inspector_content_end
            let next_end = b:vlime_inspector_content_end + range_size
            call b:vlime_conn.InspectorRange(next_start, next_end,
                        \ {c, r -> c.ui.OnInspect(c,
                            \ [{'name': 'TITLE', 'package': 'KEYWORD'}, b:vlime_inspector_title,
                                \ {'name': 'CONTENT', 'package': 'KEYWORD'}, r],
                            \ v:null, v:null)})
        elseif coord['id'] < 0
            let next_start = max([0, b:vlime_inspector_content_start - range_size])
            let next_end = b:vlime_inspector_content_start
            call b:vlime_conn.InspectorRange(next_start, next_end,
                        \ {c, r -> c.ui.OnInspect(c,
                            \ [{'name': 'TITLE', 'package': 'KEYWORD'}, b:vlime_inspector_title,
                                \ {'name': 'CONTENT', 'package': 'KEYWORD'}, r],
                            \ v:null, v:null)})
        else
            echom 'Fetching all inspector content, please wait...'
            let acc = {'TITLE': b:vlime_inspector_title, 'CONTENT': [[], 0, 0, 0]}
            call b:vlime_conn.InspectorRange(0, range_size,
                        \ function('s:InspectorFetchAllCB', [acc]))
        endif
    endif
endfunction

function! vlime#ui#inspector#NextField(forward)
    if len(b:vlime_inspector_coords) <= 0
        return
    endif

    let cur_pos = getcurpos()
    let sorted_coords = sort(copy(b:vlime_inspector_coords),
                \ function('s:CoordSorter', [a:forward]))
    let next_coord = v:null
    for c in sorted_coords
        if a:forward
            if c['begin'][0] > cur_pos[1]
                let next_coord = c
                break
            elseif c['begin'][0] == cur_pos[1] && c['begin'][1] > cur_pos[2]
                let next_coord = c
                break
            endif
        else
            if c['begin'][0] < cur_pos[1]
                let next_coord = c
                break
            elseif c['begin'][0] == cur_pos[1] && c['begin'][1] < cur_pos[2]
                let next_coord = c
                break
            endif
        endif
    endfor

    if type(next_coord) == v:t_none
        let next_coord = sorted_coords[0]
    endif

    call setpos('.', [0, next_coord['begin'][0],
                    \ next_coord['begin'][1], 0,
                    \ next_coord['begin'][1]])
endfunction

function! vlime#ui#inspector#InspectorPop()
    call b:vlime_conn.InspectorPop(function('s:OnInspectorPopComplete'))
endfunction

function! s:OnInspectorPopComplete(conn, result)
    if type(a:result) == v:t_none
        call vlime#ui#ErrMsg('The inspector stack is empty.')
    else
        call a:conn.ui.OnInspect(a:conn, a:result, v:null, v:null)
    endif
endfunction

function! s:InspectorFetchAllCB(acc, conn, result)
    if type(a:result[0]) != v:t_none
        let a:acc['CONTENT'][0] += a:result[0]
    endif
    if a:result[1] > a:result[3]
        let range_size = a:result[3] - a:result[2]
        call a:conn.InspectorRange(a:result[3], a:result[3] + range_size,
                    \ function('s:InspectorFetchAllCB', [a:acc]))
    else
        let a:acc['CONTENT'][1] = len(a:acc['CONTENT'][0])
        let a:acc['CONTENT'][3] = a:acc['CONTENT'][1]
        let full_content = [{'name': 'TITLE', 'package': 'KEYWORD'}, a:acc['TITLE'],
                    \ {'name': 'CONTENT', 'package': 'KEYWORD'}, a:acc['CONTENT']]
        call a:conn.ui.OnInspect(a:conn, full_content, v:null, v:null)
        echom 'Done fetching inspector content.'
    endif
endfunction

function! s:CoordSorter(direction, c1, c2)
    if a:c1['begin'][0] > a:c2['begin'][0]
        return a:direction ? 1 : -1
    elseif a:c1['begin'][0] == a:c2['begin'][0]
        if a:c1['begin'][1] > a:c2['begin'][1]
            return a:direction ? 1 : -1
        elseif a:c1['begin'][1] == a:c2['begin'][1]
            return 0
        else
            return a:direction ? -1 : 1
        endif
    else
        return a:direction ? -1 : 1
    endif
endfunction

function! s:InitInspectorBuf()
    nnoremap <buffer> <silent> <cr> :call vlime#ui#inspector#InspectorSelect()<cr>
    nnoremap <buffer> <silent> <space> :call vlime#ui#inspector#InspectorSelect()<cr>
    nnoremap <buffer> <silent> <tab> :call vlime#ui#inspector#NextField(v:true)<cr>
    nnoremap <buffer> <silent> <c-n> :call vlime#ui#inspector#NextField(v:true)<cr>
    nnoremap <buffer> <silent> <c-p> :call vlime#ui#inspector#NextField(v:false)<cr>
    nnoremap <buffer> <silent> p :call vlime#ui#inspector#InspectorPop()<cr>
    nnoremap <buffer> <silent> R :call b:vlime_conn.InspectorReinspect({c, r -> c.ui.OnInspect(c, r, v:null, v:null)})<cr>
endfunction
