###############################################################################
#
# SageMathCloud: A collaborative web-based interface to Sage, IPython, LaTeX and the Terminal.
#
#    Copyright (C) 2014, William Stein
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
###############################################################################


###############################################################################
#
# Project page -- browse the files in a project, etc.
#
###############################################################################

underscore      = require('underscore')


{IS_MOBILE}     = require("feature")
{top_navbar}    = require('top_navbar')
{salvus_client} = require('salvus_client')
{alert_message} = require('alerts')
async           = require('async')
misc            = require('misc')
misc_page       = require('misc_page')

{flux}          = require('flux')

{filename_extension, defaults, required, to_json, from_json, trunc, keys, uuid} = misc
{file_associations, Editor, local_storage, public_access_supported} = require('editor')

{download_file} = misc_page

# How long to cache public paths in this project
PUBLIC_PATHS_CACHE_TIMEOUT_MS = 1000*60

##################################################
# Define the project page class
##################################################

class ProjectPage
    constructor: (@project_id) ->
        if typeof(@project_id) != 'string'
            throw Error('ProjectPage constructor now takes a string')
        @project = {project_id: @project_id}   # TODO: a lot of other code assumes the ProjectPage has this; since this is going away with flux-ification, who cares for now...

        # the html container for everything in the project.
        @container = $("#salvus-project-templates").find(".salvus-project").clone()
        @container.data('project', @)
        $("body").append(@container)

        # react initialization
        flux            = require('flux').flux
        @actions        = flux.getProjectActions(@project_id)
        @store          = flux.getProjectStore(@project_id)
        @projects_store = flux.getStore('projects')

        flux.getActions('projects').set_project_state_open(@project_id)

        @projects_store.wait
            until   : (s) => s.get_my_group(@project_id)
            timeout : 60
            cb      : (err, group) =>
                if not err
                    @public_access = (group == 'public')
                    if @public_access
                        @container.find(".salvus-project-write-access").hide()
                        @container.find(".salvus-project-public-access").show()
                    else
                        @container.find(".salvus-project-write-access").show()
                        @container.find(".salvus-project-public-access").hide()

        @init_new_tab_in_navbar()
        @init_tabs()
        @create_editor()
        @init_sortable_editor_tabs()
        #@projects_store.on('change', @render)

    activity_indicator: () =>
        top_navbar.activity_indicator(@project_id)

    # call when project is closed completely
    destroy: () =>
        #@projects_store?.removeListener('change', @render)
        @save_browser_local_data()
        @container.empty()
        @editor?.destroy()
        delete project_pages[@project_id]
        @project_log?.disconnect_from_session()
        clearInterval(@_update_last_snapshot_time)
        @_cmdline?.unbind('keydown', @mini_command_line_keydown)
        delete @editor
        flux = require('flux').flux
        flux.getActions('projects').set_project_state_close(@project_id)
        require('project_store').deleteStoreActionsTable(@project_id, flux)
        delete @projects_store
        delete @actions
        delete @store

    init_new_tab_in_navbar: () =>
        # Create a new tab in the top navbar (using top_navbar as a jquery plugin)
        @container.top_navbar
            id    : @project_id
            label : @project_id
            icon  : 'fa-edit'

            onclose : () =>
                # do on next render loop since react flips if we do this too soon.
                setTimeout(@destroy, 1)

            onblur: () =>
                @editor?.remove_handlers()
                require('flux').flux.getActions('projects').setTo(foreground_project:undefined) # TODO: temporary

            onshow: () =>
                if @project?
                    @actions.push_state()
                @editor?.activate_handlers()
                @editor?.refresh()
                #TODO: this will go away
                require('misc_page').set_window_title(require('flux').flux.getStore('projects').get_title(@project_id))  # change title bar
                require('flux').flux.getActions('projects').setTo(foreground_project: @project_id)

            onfullscreen: (entering) =>
                if @project?
                    if entering
                        @hide_tabs()
                    else
                        @show_tabs()
                    $(window).resize()

        # Replace actual tab content by a React component that gets dynamically updated
        # when the project title is changed, and can display other information from the store.
        require('project_settings').init_top_navbar(@project_id)


    init_sortable_file_list: () =>
        # make the list of open files user-sortable.
        if @_file_list_is_sortable
            return
        @container.find(".file-pages").sortable
            axis                 : 'x'
            delay                : 50
            containment          : 'parent'
            tolerance            : 'pointer'
            placeholder          : 'file-tab-placeholder'
            forcePlaceholderSize : true
        @_file_list_is_sortable = true

    destroy_sortable_file_list: () =>
        if not @_file_list_is_sortable
            return
        @container.find(".file-pages").sortable("destroy")
        @_file_list_is_sortable = false


    #  files/....
    #  recent
    #  new
    #  log
    #  settings
    #  search
    load_target: (target, foreground=true) =>
        #console.log("project -- load_target=#{target}")
        segments = target.split('/')
        #console.log("segments=",segments)
        switch segments[0]
            when 'files'
                if target[target.length-1] == '/'
                    # open a directory
                    #console.log("change to ", segments.slice(1, segments.length-1))
                    @set_current_path(segments.slice(1, segments.length-1).join('/'))
                    @display_tab("project-file-listing")
                else
                    # open a file -- foreground option is relevant here.
                    if foreground
                        @set_current_path(segments.slice(1, segments.length-1).join('/'))
                        @display_tab("project-editor")
                    @open_file
                        path       : segments.slice(1).join('/')
                        foreground : foreground
            when 'new'  # ignore foreground for these and below, since would be nonsense
                @set_current_path(segments.slice(1).join('/'))
                @display_tab("project-new-file")
            when 'log'
                @display_tab("project-activity")
            when 'settings'
                @display_tab("project-settings")
            when 'search'
                @set_current_path(segments.slice(1).join('/'))
                @display_tab("project-search")

    close: () =>
        top_navbar.remove_page(@project_id)

    # Reload the @project attribute from the database, and re-initialize
    # ui elements, mainly in settings.
    reload_settings: (cb) =>
        @project = flux.getStore('projects').get_project(@project_id)
        cb?()

    ########################################
    # Launch open sessions
    ########################################

    # TODO -- not used right now -- just use init_file_sessions only -- delete this.
    init_open_sessions: (cb) =>
        salvus_client.project_session_info
            project_id: @project_id
            cb: (err, mesg) =>
                if err
                    alert_message(type:"error", message:"Error getting open sessions -- #{err}")
                    cb?(err)
                    return
                #console.log(mesg)
                if not (mesg? and mesg.info?)
                    cb?()
                    return

                async.series([
                    (cb) =>
                        @init_console_sessions(mesg.info.console_sessions, cb)
                    (cb) =>
                        @init_sage_sessions(mesg.info.sage_sessions, cb)
                    (cb) =>
                        @init_file_sessions(mesg.info.file_sessions, cb)
                ], (err) => cb?(err))

    init_sortable_editor_tabs: () =>
        @container.find(".nav.projects").sortable
            axis                 : 'x'
            delay                : 50
            containment          : 'parent'
            tolerance            : 'pointer'
            placeholder          : 'nav-projects-placeholder'
            forcePlaceholderSize : true

    ########################################
    # ...?
    ########################################

    hide_tabs: () =>
        @container.find(".project-pages").hide()
        @container.find(".file-pages").hide()

    show_tabs: () =>
        @container.find(".project-pages").show()
        @container.find(".file-pages").show()

    init_tabs: () =>
        @tabs = []
        that = @
        for item in @container.find(".project-pages").children()
            t = $(item)
            target = t.find("a").data('target')
            if not target?
                continue

            # activate any a[href=...] links elsewhere on the page
            @container.find("a[href=##{target}]").data('item',t).data('target',target).click () ->
                link = $(@)
                if link.data('item').hasClass('disabled')
                    return false
                that.display_tab(link.data('target'))
                return false

            t.find('a').tooltip(delay:{ show: 1000, hide: 200 })
            name = target
            tab = {label:t, name:name, target:@container.find(".#{name}")}
            @tabs.push(tab)

            t.find("a").data('item',t).click () ->
                link = $(@)
                if link.data('item').hasClass('disabled')
                    return false
                that.display_tab(link.data("target"))
                return false

            if name == "project-file-listing"
                tab.onshow = () ->
                    that.editor?.hide_editor_content()
                    require('project_files').render_new(that.project.project_id, that.container.find(".smc-react-project-files")[0], flux)
                    that.actions.set_url_to_path(that.store.state.current_path)
                tab.onblur = () ->
                    require('project_files').unmount(that.container.find(".smc-react-project-files")[0])
            else if name == "project-editor"
                tab.onshow = () ->
                    that.editor.onshow()
                t.find("a").click () ->
                    that.editor.hide()
                    that.editor.show_recent()
                    return false
            else if name == "project-new-file" and not @public_access
                tab.onshow = () ->
                    that.editor?.hide_editor_content()
                    require('project_new').render_new(that.project.project_id, that.container.find(".smc-react-project-new")[0], flux)
                    that.actions.push_state('new/' + that.store.state.current_path)
                tab.onblur = ->
                    require('project_new').unmount(that.container.find(".smc-react-project-new")[0])
            else if name == "project-activity" and not @public_access
                tab.onshow = () =>
                    require('project_log').render_log(that.project.project_id, that.container.find(".smc-react-project-log")[0], flux)
                    that.editor?.hide_editor_content()
                    that.actions.push_state('log')
                    # HORRIBLE TEMPORARY HACK since focus isn't working with react... yet  (TODO)
                    @container.find(".project-activity").find("input").focus()
                tab.onblur = ->
                    require('project_log').unmount(that.container.find(".smc-react-project-log")[0])

            else if name == "project-settings" and not @public_access
                tab.onshow = () ->
                    require('project_settings').create_page(that.project.project_id, that.container.find(".smc-react-project-settings")[0], flux)
                    that.editor?.hide_editor_content()
                    that.actions.push_state('settings')
                    url = document.URL
                    i = url.lastIndexOf("/settings")
                    if i != -1
                        url = url.slice(0,i)
                    that.container.find(".salvus-settings-url").val(url)
                tab.onblur = ->
                    require('project_settings').unmount(that.container.find(".smc-react-project-settings")[0])

            else if name == "project-search" and not @public_access
                tab.onshow = () ->
                    require('project_search').render_project_search(that.project.project_id, that.container.find(".smc-react-project-search")[0], flux)
                    that.editor?.hide_editor_content()
                    that.actions.push_state('search/' + that.store.state.current_path)
                    that.container.find(".project-search-form-input").focus()
                tab.onblur = ->
                    require('project_search').unmount(that.container.find(".smc-react-project-search")[0])


        for item in @container.find(".file-pages").children()
            t = $(item)
            target = t.find("a").data('target')
            if not target?
                continue

            # activate any a[href=...] links elsewhere on the page
            @container.find("a[href=##{target}]").data('item',t).data('target',target).click () ->
                link = $(@)
                if link.data('item').hasClass('disabled')
                    return false
                that.display_tab(link.data('target'))
                return false

            t.find('a').tooltip(delay:{ show: 1000, hide: 200 })
            name = target
            tab = {label:t, name:name, target:@container.find(".#{name}")}
            @tabs.push(tab)

            t.find("a").data('item',t).click () ->
                link = $(@)
                if link.data('item').hasClass('disabled')
                    return false
                that.display_tab(link.data("target"))
                return false

        @display_tab("project-file-listing")

    create_editor: (initial_files) =>   # initial_files (optional)
        @editor = new Editor
            project_page  : @
            counter       : @container.find(".project-editor-file-count")
            initial_files : initial_files
        @container.find(".project-editor").append(@editor.element)

    display_tab: (name) =>
        if @_last_display_tab_name == name
            # tab already displayed
            return
        @container.find(".project-pages").children().removeClass('active')
        @container.find(".file-pages").children().removeClass('active')
        @container.css(position: 'static')
        
        # hide the currently open tab
        for tab in @tabs
            if tab.name == @_last_display_tab_name
                tab.onblur?()
                tab.target.hide()
                break
        @_last_display_tab_name = name
        # show the tab we are opening
        for tab in @tabs
            if tab.name == name
                @current_tab = tab
                tab.target.show()
                tab.label.addClass('active')
                tab.onshow?()
                @focus()
                break
        # fix the size of the tabs at the top
        @editor?.resize_open_file_tabs()

        if name == 'project-new-file'
            @actions.set_next_default_filename(require('account').default_filename())

        if name == 'project-file-listing'
            #temporary
            sort_by_time = @store.state.sort_by_time ? true
            show_hidden = @store.state.show_hidden ? false
            @actions.set_directory_files(@store.state.current_path, sort_by_time, show_hidden)

    show_editor_chat_window: (path) =>
        @editor?.show_chat_window(path)

    save_browser_local_data: (cb) =>
        @editor.save(undefined, cb)

    # Return the string representation of the current path, as a
    # relative path from the root of the project.
    current_pathname: () => @store.state.current_path

    # Set the current path array from a path string to a directory
    set_current_path: (path) =>
        if path != @store.state.current_path
            require('flux').flux.getProjectActions(@project_id).set_current_path(path)

    focus: () =>
        if not IS_MOBILE  # do *NOT* do on mobile, since is very annoying to have a keyboard pop up.
            switch @current_tab.name
                when "project-file-listing"
                    @container.find(".salvus-project-search-for-file-input").focus()
                #when "project-editor"
                #    @editor.focus()

    default_filename: (ext) =>
        return require('account').default_filename(ext)

    ensure_directory_exists: (opts) =>
        opts = defaults opts,
            path  : required
            cb    : undefined  # cb(true or false)
            alert : true
        salvus_client.exec
            project_id : @project_id
            command    : "mkdir"
            timeout    : 15
            args       : ['-p', opts.path]
            cb         : (err, result) =>
                if opts.alert
                    if err
                        alert_message(type:"error", message:err)
                    else if result.event == 'error'
                        alert_message(type:"error", message:result.error)
                opts.cb?(err or result.event == 'error')

    ensure_file_exists: (opts) =>
        opts = defaults opts,
            path  : required
            cb    : undefined  # cb(true or false)
            alert : true

        async.series([
            (cb) =>
                dir = misc.path_split(opts.path).head
                if dir == ''
                    cb()
                else
                    @ensure_directory_exists(path:dir, alert:opts.alert, cb:cb)
            (cb) =>
                #console.log("ensure_file_exists -- touching '#{opts.path}'")
                salvus_client.exec
                    project_id : @project_id
                    command    : "touch"
                    timeout    : 15
                    args       : [opts.path]
                    cb         : (err, result) =>
                        if opts.alert
                            if err
                                alert_message(type:"error", message:err)
                            else if result.event == 'error'
                                alert_message(type:"error", message:result.error)
                        opts.cb?(err or result.event == 'error')
        ], (err) -> opts.cb?(err))

    get_from_web: (opts) =>
        opts = defaults opts,
            url     : required
            dest    : undefined
            timeout : 45
            alert   : true
            cb      : undefined     # cb(true or false, depending on error)

        {command, args} = transform_get_url(opts.url)

        salvus_client.exec
            project_id : @project_id
            command    : command
            timeout    : opts.timeout
            path       : opts.dest
            args       : args
            cb         : (err, result) =>
                if opts.alert
                    if err
                        alert_message(type:"error", message:err)
                    else if result.event == 'error'
                        alert_message(type:"error", message:result.error)
                opts.cb?(err or result.event == 'error')


    open_file_in_another_browser_tab: (path) =>
        salvus_client.read_file_from_project
            project_id : @project_id
            path       : path
            cb         : (err, result) =>
                window.open(misc.encode_path(result.url))

    open_file: (opts) =>
        opts = defaults opts,
            path       : required
            foreground : true      # display in foreground as soon as possible

        ext = filename_extension(opts.path)

        if @public_access and not public_access_supported(opts.path)
            alert_message(type:"error", message: "Opening '#{opts.path}' publicly not yet supported.")
            return

        @editor.open opts.path, (err, opened_path) =>
            if err
                # ga('send', 'event', 'file', 'open', 'error', opts.path, {'nonInteraction': 1})
                alert_message(type:"error", message:"Error opening '#{opts.path}' -- #{misc.to_json(err)}", timeout:10)
            else
                # ga('send', 'event', 'file', 'open', 'success', opts.path, {'nonInteraction': 1})
                if opts.foreground
                    @display_tab("project-editor")

                # make tab for this file actually visible in the editor
                @editor.display_tab
                    path       : opened_path
                    foreground : opts.foreground

    show_add_collaborators_box: () =>
        @display_tab('project-settings')

    download_file: (opts) =>
        opts = defaults opts,
            path    : required
            auto    : true
            timeout : 45
            cb      : undefined   # cb(err) when file download from browser starts -- instant since we use raw path

        if misc.filename_extension(opts.path) == 'pdf'
            # unfortunately, download_file doesn't work for pdf these days...
            opts.auto = false

        url = "#{window.salvus_base_url}/#{@project_id}/raw/#{misc.encode_path(opts.path)}"
        if opts.auto
            download_file(url)
        else
            window.open(url)

project_pages = {}

# Function that returns the project page for the project with given id,
# or creates it if it doesn't exist.
project_page = exports.project_page = (project_id) ->
    if typeof(project_id) != 'string'
        throw Error('ProjectPage constructor now takes a string')
    p = project_pages[project_id]
    if p?
        return p
    p = project_pages[project_id] = new ProjectPage(project_id)
    top_navbar.init_sortable_project_list()
    return p


# Apply various transformations to url's before downloading a file using the "+ New" from web thing:
# This is useful, since people often post a link to a page that *hosts* raw content, but isn't raw
# content, e.g., ipython nbviewer, trac patches, github source files (or repos?), etc.

URL_TRANSFORMS =
    'http://trac.sagemath.org/attachment/ticket/':'http://trac.sagemath.org/raw-attachment/ticket/'
    'http://nbviewer.ipython.org/urls/':'https://'


transform_get_url = (url) ->  # returns something like {command:'wget', args:['http://...']}
    if misc.startswith(url, "https://github.com/") and url.indexOf('/blob/') != -1
        url = url.replace("https://github.com", "https://raw.github.com").replace("/blob/","/")

    if misc.startswith(url, 'git@github.com:')
        command = 'git'  # kind of useless due to host keys...
        args = ['clone', url]
    else if url.slice(url.length-4) == ".git"
        command = 'git'
        args = ['clone', url]
    else
        # fall back
        for a,b of URL_TRANSFORMS
            url = url.replace(a,b)  # only replaces first instance, unlike python.  ok for us.
        command = 'wget'
        args = [url]

    return {command:command, args:args}