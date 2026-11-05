" viminfo.vim - report the current file and cursor position to work-mcp.
"
" Posts to work-mcp's /viminfo endpoint (see viminfo.go) whenever the cursor
" settles, along with the other files open in vim, and clears it all when vim
" exits. Works in Vim 8+ and Neovim;
" needs curl on $PATH.
"
" Install: symlink or copy into ~/.vim/plugin/ (or ~/.config/nvim/plugin/).
"
" Options:
"   g:viminfo_url      endpoint (default 'http://127.0.0.1:7865/viminfo')
"   g:viminfo_delay    ms the cursor must rest before sending (default 200)
"   g:viminfo_enabled  set to 0 to stop sending (default 1)
"
" Commands:
"   :VimInfoSend       send now, synchronously, and report the result
"   :VimInfoEnable     start sending
"   :VimInfoDisable    stop sending and clear the position on the server

if exists('g:loaded_work_viminfo') || !has('timers') || !exists('*json_encode')
  finish
endif
let g:loaded_work_viminfo = 1

let g:viminfo_url = get(g:, 'viminfo_url', 'http://127.0.0.1:7865/viminfo')
let g:viminfo_delay = get(g:, 'viminfo_delay', 200)
let g:viminfo_enabled = get(g:, 'viminfo_enabled', 1)

" The server's "relative" field is relative to where vim was started.
let s:start_dir = fnamemodify(getcwd(), ':p')
let s:timer = -1
let s:last = ''
let s:last_at = 0
" Resend an unchanged position after this many seconds, so the server's
" age_seconds reflects that vim is still open rather than idle or closed.
let s:refresh = 30

" Report at most this many other open files, most recently used first.
let s:max_buffers = 50

function! s:relative(file) abort
  return stridx(a:file, s:start_dir) == 0 ? a:file[len(s:start_dir):] : ''
endfunction

" The other listed buffers that hold files, most recently used first.
function! s:buffers() abort
  let infos = filter(getbufinfo({'buflisted': 1}),
        \ 'v:val.bufnr != bufnr("%") && v:val.name !=# "" && getbufvar(v:val.bufnr, "&buftype") ==# ""')
  call sort(infos, {a, b -> get(b, 'lastused', 0) - get(a, 'lastused', 0)})
  let out = []
  for b in infos[: s:max_buffers - 1]
    let file = fnamemodify(b.name, ':p')
    " b.windows spans all tabs; prefer a window in the current tab.
    let here = filter(copy(b.windows), 'win_id2tabwin(v:val)[0] == tabpagenr()')
    let win = empty(here) ? get(b.windows, 0, 0) : here[0]
    let item = {
          \ 'file': file,
          \ 'modified': b.changed ? v:true : v:false,
          \ 'visible': empty(here) ? v:false : v:true,
          \ }
    if win
      let item.tab = win_id2tabwin(win)[0]
    endif
    " A file shown in a window has its cursor there; otherwise use the line
    " the cursor was on when it was last shown.
    let lnum = win ? line('.', win) : b.lnum
    if lnum > 0
      let item.line = lnum
    endif
    let rel = s:relative(file)
    if rel !=# ''
      let item.relative = rel
    endif
    call add(out, item)
  endfor
  return out
endfunction

" JSON for the current window, or '' if it isn't showing a file.
function! s:payload() abort
  if &buftype !=# ''
    return ''
  endif
  let file = expand('%:p')
  if file ==# ''
    return ''
  endif
  let p = {
        \ 'file': file,
        \ 'line': line('.'),
        \ 'col': col('.'),
        \ 'visible': [line('w0'), line('w$')],
        \ 'filetype': &filetype,
        \ 'tab': tabpagenr(),
        \ 'modified': &modified ? v:true : v:false,
        \ 'buffers': s:buffers(),
        \ }
  let rel = s:relative(file)
  if rel !=# ''
    let p.relative = rel
  endif
  return json_encode(p)
endfunction

function! s:cmd(method, body) abort
  let cmd = ['curl', '-s', '--max-time', '2', '-o', '/dev/null', '-w', '%{http_code}', '-X', a:method]
  if a:body !=# ''
    let cmd += ['-H', 'Content-Type: application/json', '--data-binary', a:body]
  endif
  return add(cmd, g:viminfo_url)
endfunction

" Fire and forget, so a slow or absent server never blocks editing.
function! s:send_async(method, body) abort
  let cmd = s:cmd(a:method, a:body)
  if has('nvim')
    call jobstart(cmd)
  elseif has('job')
    call job_start(cmd, {'in_io': 'null', 'out_io': 'null', 'err_io': 'null'})
  endif
endfunction

" Blocking send; returns the HTTP status code ('000' if unreachable).
function! s:send_sync(method, body) abort
  return system(join(map(s:cmd(a:method, a:body), 'shellescape(v:val)')))
endfunction

function! s:fire(...) abort
  let s:timer = -1
  let body = s:payload()
  if body ==# '' || (body ==# s:last && localtime() - s:last_at < s:refresh)
    return
  endif
  let s:last = body
  let s:last_at = localtime()
  call s:send_async('POST', body)
endfunction

function! s:schedule() abort
  if !g:viminfo_enabled
    return
  endif
  if s:timer != -1
    call timer_stop(s:timer)
  endif
  let s:timer = timer_start(g:viminfo_delay, function('s:fire'))
endfunction

function! s:clear_on_exit() abort
  " Only if we reported something; a synchronous call keeps the request
  " from being killed along with vim, and is skipped otherwise.
  if g:viminfo_enabled && s:last_at > 0
    call s:send_sync('DELETE', '')
  endif
endfunction

function! s:send_now() abort
  let body = s:payload()
  if body ==# ''
    echohl WarningMsg | echo 'viminfo: current window is not a file' | echohl None
    return
  endif
  let code = s:send_sync('POST', body)
  if code ==# '204'
    let s:last = body
    let s:last_at = localtime()
    echo 'viminfo: sent ' . body
  else
    echohl ErrorMsg | echo 'viminfo: ' . g:viminfo_url . ' returned ' . code | echohl None
  endif
endfunction

function! s:enable(on) abort
  let g:viminfo_enabled = a:on
  if a:on
    let s:last = ''
    call s:schedule()
  else
    if s:timer != -1
      call timer_stop(s:timer)
      let s:timer = -1
    endif
    call s:send_async('DELETE', '')
    let s:last_at = 0
  endif
endfunction

command! -bar VimInfoSend call s:send_now()
command! -bar VimInfoEnable call s:enable(1)
command! -bar VimInfoDisable call s:enable(0)

augroup work_viminfo
  autocmd!
  autocmd CursorMoved,CursorMovedI,BufEnter,WinEnter,TabEnter,FocusGained * call s:schedule()
  " The modified flag changes on edits and writes.
  autocmd TextChanged,TextChangedI,BufWritePost * call s:schedule()
  " The list of other open files changes.
  autocmd BufAdd,BufDelete * call s:schedule()
  if exists('##WinScrolled')
    autocmd WinScrolled * call s:schedule()
  endif
  " Another vim may report in between; send again when this one is used.
  autocmd FocusGained * let s:last = ''
  autocmd VimLeavePre * call s:clear_on_exit()
augroup END

if !executable('curl')
  echohl WarningMsg | echomsg 'viminfo: curl not found, positions will not be sent' | echohl None
endif
