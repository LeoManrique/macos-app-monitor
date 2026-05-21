use std::collections::{HashMap, HashSet};
use std::ffi::c_void;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use gpui::{
    actions, div, img, prelude::*, px, rgb, size, uniform_list, Application, Context, FontWeight,
    Image as GpuiImage, ImageFormat, KeyBinding, Menu, MenuItem, MouseButton, SharedString,
    Window, WindowBounds, WindowOptions,
};
use sysinfo::Disks;

mod palette {
    pub const BG: u32 = 0x232323;
    pub const BG_ALT: u32 = 0x282828;
    pub const HEADER_BG: u32 = 0x2c2c2c;
    pub const APP_ROW_BG: u32 = 0x2a2a2a;
    pub const HOVER_BG: u32 = 0x333333;
    pub const BORDER: u32 = 0x3a3a3a;
    pub const TEXT_PRIMARY: u32 = 0xe8e8e8;
    pub const TEXT_SECONDARY: u32 = 0xa0a0a0;
    pub const TEXT_MUTED: u32 = 0x8a8a8a;
    pub const TEXT_APP_NAME: u32 = 0xf5f5f5;
}

actions!(
    activity_monitor,
    [Quit, HideApp, Minimize, Zoom, ToggleFullscreen]
);
use sysinfo::{ProcessesToUpdate, System};

#[repr(C)]
#[derive(Default)]
struct RusageInfoV4 {
    ri_uuid: [u8; 16],
    ri_user_time: u64,
    ri_system_time: u64,
    ri_pkg_idle_wkups: u64,
    ri_interrupt_wkups: u64,
    ri_pageins: u64,
    ri_wired_size: u64,
    ri_resident_size: u64,
    ri_phys_footprint: u64,
    ri_proc_start_abstime: u64,
    ri_proc_exit_abstime: u64,
    ri_child_user_time: u64,
    ri_child_system_time: u64,
    ri_child_pkg_idle_wkups: u64,
    ri_child_interrupt_wkups: u64,
    ri_child_pageins: u64,
    ri_child_elapsed_abstime: u64,
    ri_diskio_bytesread: u64,
    ri_diskio_byteswritten: u64,
    ri_cpu_time_qos_default: u64,
    ri_cpu_time_qos_maintenance: u64,
    ri_cpu_time_qos_background: u64,
    ri_cpu_time_qos_utility: u64,
    ri_cpu_time_qos_legacy: u64,
    ri_cpu_time_qos_user_initiated: u64,
    ri_cpu_time_qos_user_interactive: u64,
    ri_billed_system_time: u64,
    ri_serviced_system_time: u64,
    ri_logical_writes: u64,
    ri_lifetime_max_phys_footprint: u64,
    ri_instructions: u64,
    ri_cycles: u64,
    ri_billed_energy: u64,
    ri_serviced_energy: u64,
    ri_interval_max_phys_footprint: u64,
    ri_runnable_time: u64,
}

unsafe extern "C" {
    fn proc_pid_rusage(pid: i32, flavor: i32, buffer: *mut c_void) -> i32;
}

const RUSAGE_INFO_V4: i32 = 4;

fn phys_footprint(pid: u32) -> Option<u64> {
    let mut info = RusageInfoV4::default();
    let r = unsafe {
        proc_pid_rusage(
            pid as i32,
            RUSAGE_INFO_V4,
            &mut info as *mut _ as *mut c_void,
        )
    };
    if r == 0 {
        Some(info.ri_phys_footprint)
    } else {
        None
    }
}

fn app_path_for_exe(exe: &Path) -> Option<(String, PathBuf)> {
    let s = exe.to_str()?;
    let idx = s.find(".app/")?;
    let prefix = &s[..idx];
    let name_start = prefix.rfind('/').map(|p| p + 1).unwrap_or(0);
    let name = s[name_start..idx].to_string();
    let bundle = PathBuf::from(&s[..idx + 4]);
    Some((name, bundle))
}

fn load_app_icon(bundle: &Path) -> Option<Arc<GpuiImage>> {
    let info_path = bundle.join("Contents/Info.plist");
    let plist: plist::Value = plist::from_file(&info_path).ok()?;
    let dict = plist.as_dictionary()?;
    let icon_file = dict.get("CFBundleIconFile")?.as_string()?;
    let resources = bundle.join("Contents/Resources");
    let with_ext = if icon_file.ends_with(".icns") {
        resources.join(icon_file)
    } else {
        resources.join(format!("{}.icns", icon_file))
    };
    if !with_ext.exists() {
        return None;
    }
    let bytes = std::fs::read(&with_ext).ok()?;

    // Electron-based apps (GitHub Desktop, VS Code forks, etc.) ship a raw PNG
    // file with a `.icns` extension. NSImage tolerates this; the `icns` crate
    // rejects it on magic-byte mismatch. Treat PNG-disguised-as-icns as PNG.
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Some(Arc::new(GpuiImage::from_bytes(ImageFormat::Png, bytes)));
    }

    let family = icns::IconFamily::read(std::io::Cursor::new(&bytes)).ok()?;
    let icon_type = family
        .available_icons()
        .into_iter()
        .max_by_key(|t| t.pixel_width() * t.pixel_height())?;
    let image = family.get_icon_with_type(icon_type).ok()?;
    let mut png = Vec::new();
    image.write_png(&mut png).ok()?;
    Some(Arc::new(GpuiImage::from_bytes(ImageFormat::Png, png)))
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum SortColumn {
    Pid,
    Name,
    Cpu,
    Memory,
}

impl SortColumn {
    fn default_dir(self) -> SortDir {
        match self {
            Self::Pid | Self::Name => SortDir::Asc,
            Self::Cpu | Self::Memory => SortDir::Desc,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum SortDir {
    Asc,
    Desc,
}

#[derive(Clone, Copy)]
struct SortState {
    column: SortColumn,
    dir: SortDir,
}

impl Default for SortState {
    fn default() -> Self {
        Self {
            column: SortColumn::Memory,
            dir: SortDir::Desc,
        }
    }
}

#[derive(Clone)]
struct ProcessInfo {
    pid: u32,
    name: SharedString,
    memory_bytes: u64,
    cpu: f32,
}

struct AppGroup {
    key: SharedString,
    row_id: SharedString,
    display_name: SharedString,
    is_app_bundle: bool,
    bundle_path: Option<PathBuf>,
    total_memory: u64,
    total_cpu: f32,
    processes: Vec<ProcessInfo>,
}

#[derive(Default, Clone, Copy)]
struct SystemStats {
    total_memory: u64,
    used_memory: u64,
    global_cpu: f32,
    total_disk: u64,
    free_disk: u64,
}

struct ProcessMonitor {
    system: System,
    disks: Disks,
    groups: Arc<Vec<AppGroup>>,
    expanded: HashSet<SharedString>,
    sort: SortState,
    icons: HashMap<SharedString, Option<Arc<GpuiImage>>>,
    stats: SystemStats,
}

fn sort_processes(procs: &mut [ProcessInfo], sort: SortState) {
    use std::cmp::Ordering;
    procs.sort_by(|a, b| {
        let ord = match sort.column {
            SortColumn::Pid => a.pid.cmp(&b.pid),
            SortColumn::Name => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
            SortColumn::Cpu => a.cpu.partial_cmp(&b.cpu).unwrap_or(Ordering::Equal),
            SortColumn::Memory => a.memory_bytes.cmp(&b.memory_bytes),
        };
        if sort.dir == SortDir::Desc { ord.reverse() } else { ord }
    });
}

fn sort_groups(groups: &mut [AppGroup], sort: SortState) {
    use std::cmp::Ordering;
    groups.sort_by(|a, b| {
        let ord = match sort.column {
            SortColumn::Pid => {
                let a_min = a.processes.iter().map(|p| p.pid).min().unwrap_or(0);
                let b_min = b.processes.iter().map(|p| p.pid).min().unwrap_or(0);
                a_min.cmp(&b_min)
            }
            SortColumn::Name => a
                .display_name
                .to_lowercase()
                .cmp(&b.display_name.to_lowercase()),
            SortColumn::Cpu => a
                .total_cpu
                .partial_cmp(&b.total_cpu)
                .unwrap_or(Ordering::Equal),
            SortColumn::Memory => a.total_memory.cmp(&b.total_memory),
        };
        if sort.dir == SortDir::Desc { ord.reverse() } else { ord }
    });
}

fn build_groups(sys: &System, sort: SortState) -> Vec<AppGroup> {
    let mut by_app: HashMap<String, (bool, Option<PathBuf>, Vec<ProcessInfo>)> = HashMap::new();

    for (pid, p) in sys.processes() {
        let pid_u32 = pid.as_u32();
        let memory = phys_footprint(pid_u32).unwrap_or_else(|| p.memory());
        let cpu = p.cpu_usage();
        let proc_name = p.name().to_string_lossy().into_owned();
        let pi = ProcessInfo {
            pid: pid_u32,
            name: SharedString::from(proc_name.clone()),
            memory_bytes: memory,
            cpu,
        };
        let (key, is_app, bundle) = match p.exe().and_then(app_path_for_exe) {
            Some((app, path)) => (app, true, Some(path)),
            None => (proc_name, false, None),
        };
        let entry = by_app.entry(key).or_insert((is_app, None, Vec::new()));
        entry.0 = entry.0 || is_app;
        if entry.1.is_none() {
            entry.1 = bundle;
        }
        entry.2.push(pi);
    }

    let mut groups: Vec<AppGroup> = by_app
        .into_iter()
        .map(|(name, (is_app, bundle_path, mut processes))| {
            sort_processes(&mut processes, sort);
            let total_memory: u64 = processes.iter().map(|p| p.memory_bytes).sum();
            let total_cpu: f32 = processes.iter().map(|p| p.cpu).sum();
            let shared = SharedString::from(name);
            let row_id = SharedString::from(format!("group-{}", shared));
            AppGroup {
                key: shared.clone(),
                row_id,
                display_name: shared,
                is_app_bundle: is_app,
                bundle_path,
                total_memory,
                total_cpu,
                processes,
            }
        })
        .collect();

    sort_groups(&mut groups, sort);
    groups
}

fn read_stats(sys: &System, disks: &Disks) -> SystemStats {
    let (total_disk, free_disk) = disks
        .list()
        .iter()
        .find(|d| d.mount_point() == Path::new("/"))
        .map(|d| (d.total_space(), d.available_space()))
        .unwrap_or((0, 0));
    SystemStats {
        total_memory: sys.total_memory(),
        used_memory: sys.used_memory(),
        global_cpu: sys.global_cpu_usage(),
        total_disk,
        free_disk,
    }
}

impl ProcessMonitor {
    fn new(cx: &mut Context<Self>) -> Self {
        let mut system = System::new_all();
        system.refresh_processes(ProcessesToUpdate::All, true);
        let disks = Disks::new_with_refreshed_list();
        let sort = SortState::default();
        let groups = build_groups(&system, sort);
        let stats = read_stats(&system, &disks);
        let mut icons = HashMap::new();
        for g in &groups {
            if !icons.contains_key(&g.key) {
                let icon = g.bundle_path.as_deref().and_then(load_app_icon);
                icons.insert(g.key.clone(), icon);
            }
        }
        let groups = Arc::new(groups);

        cx.spawn(async move |this, cx| loop {
            cx.background_executor()
                .timer(Duration::from_secs(2))
                .await;
            let r = this.update(cx, |this, cx| {
                this.system
                    .refresh_processes(ProcessesToUpdate::All, true);
                this.disks.refresh(true);
                let new_groups = build_groups(&this.system, this.sort);
                for g in &new_groups {
                    if !this.icons.contains_key(&g.key) {
                        let icon = g.bundle_path.as_deref().and_then(load_app_icon);
                        this.icons.insert(g.key.clone(), icon);
                    }
                }
                this.stats = read_stats(&this.system, &this.disks);
                this.groups = Arc::new(new_groups);
                cx.notify();
            });
            if r.is_err() {
                break;
            }
        })
        .detach();

        Self {
            system,
            disks,
            groups,
            expanded: HashSet::new(),
            sort,
            icons,
            stats,
        }
    }

    fn click_column(&mut self, col: SortColumn, cx: &mut Context<Self>) {
        if self.sort.column == col {
            self.sort.dir = if self.sort.dir == SortDir::Asc {
                SortDir::Desc
            } else {
                SortDir::Asc
            };
        } else {
            self.sort = SortState {
                column: col,
                dir: col.default_dir(),
            };
        }
        self.groups = Arc::new(build_groups(&self.system, self.sort));
        cx.notify();
    }
}

fn format_memory(bytes: u64) -> String {
    let mb = bytes as f64 / 1024.0 / 1024.0;
    if mb >= 1024.0 {
        format!("{:.2} GB", mb / 1024.0)
    } else {
        format!("{:.1} MB", mb)
    }
}

fn format_cpu(pct: f32) -> String {
    format!("{:.1}", pct)
}

fn format_gb(bytes: u64) -> String {
    format!("{:.1} GB", bytes as f64 / 1024.0 / 1024.0 / 1024.0)
}

enum Row {
    AppHeader {
        key: SharedString,
        row_id: SharedString,
        display: SharedString,
        total: u64,
        total_cpu: f32,
        expanded: bool,
        icon: Option<Arc<GpuiImage>>,
    },
    Process {
        pid: u32,
        name: SharedString,
        memory: u64,
        cpu: f32,
    },
    Standalone {
        pid: u32,
        name: SharedString,
        memory: u64,
        cpu: f32,
        icon: Option<Arc<GpuiImage>>,
    },
}

fn build_rows(
    groups: &[AppGroup],
    expanded: &HashSet<SharedString>,
    icons: &HashMap<SharedString, Option<Arc<GpuiImage>>>,
) -> Vec<Row> {
    let mut out = Vec::new();
    for g in groups {
        let icon = icons.get(&g.key).cloned().flatten();
        let single_matches = g.processes.len() == 1
            && g.is_app_bundle
            && g.processes[0].name == g.display_name;
        let is_flat = !g.is_app_bundle || single_matches;
        if is_flat {
            let p = &g.processes[0];
            out.push(Row::Standalone {
                pid: p.pid,
                name: if g.is_app_bundle {
                    g.display_name.clone()
                } else {
                    p.name.clone()
                },
                memory: g.total_memory,
                cpu: g.total_cpu,
                icon: if g.is_app_bundle { icon } else { None },
            });
        } else {
            let is_expanded = expanded.contains(&g.key);
            out.push(Row::AppHeader {
                key: g.key.clone(),
                row_id: g.row_id.clone(),
                display: g.display_name.clone(),
                total: g.total_memory,
                total_cpu: g.total_cpu,
                expanded: is_expanded,
                icon,
            });
            if is_expanded {
                for p in &g.processes {
                    out.push(Row::Process {
                        pid: p.pid,
                        name: p.name.clone(),
                        memory: p.memory_bytes,
                        cpu: p.cpu,
                    });
                }
            }
        }
    }
    out
}

impl Render for ProcessMonitor {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let rows = Arc::new(build_rows(&self.groups, &self.expanded, &self.icons));
        let row_count = rows.len();
        let entity = cx.entity();
        let stats = self.stats;

        let sort = self.sort;
        let header_entity = entity.clone();
        let sort_marker = |col: SortColumn| -> &'static str {
            if sort.column == col {
                if sort.dir == SortDir::Desc { " ▾" } else { " ▴" }
            } else {
                ""
            }
        };
        let make_header_cell = {
            let header_entity = header_entity.clone();
            move |id: &'static str,
                  label: &'static str,
                  col: SortColumn,
                  width: Option<gpui::Pixels>,
                  right: bool| {
                let active = sort.column == col;
                let marker = sort_marker(col);
                let entity_for_click = header_entity.clone();
                let mut cell = div()
                    .id(id)
                    .h_full()
                    .flex()
                    .items_center()
                    .cursor_pointer()
                    .text_color(if active {
                        rgb(palette::TEXT_PRIMARY)
                    } else {
                        rgb(palette::TEXT_MUTED)
                    })
                    .hover(|s| s.text_color(rgb(palette::TEXT_PRIMARY)))
                    .on_mouse_down(MouseButton::Left, move |_, _, app| {
                        entity_for_click.update(app, |this, cx| this.click_column(col, cx));
                    })
                    .child(format!("{}{}", label, marker));
                cell = match width {
                    Some(w) => cell.w(w),
                    None => cell.flex_1(),
                };
                if right {
                    cell = cell.justify_end();
                }
                cell
            }
        };

        let header = div()
            .flex()
            .flex_row()
            .w_full()
            .h(px(30.))
            .bg(rgb(palette::HEADER_BG))
            .text_xs()
            .font_weight(FontWeight::SEMIBOLD)
            .border_b_1()
            .border_color(rgb(palette::BORDER))
            .px_3()
            .items_center()
            .child(make_header_cell("h-pid", "PID", SortColumn::Pid, Some(px(80.)), false))
            .child(make_header_cell("h-name", "Process Name", SortColumn::Name, None, false))
            .child(make_header_cell("h-cpu", "% CPU", SortColumn::Cpu, Some(px(70.)), true))
            .child(make_header_cell("h-mem", "Memory", SortColumn::Memory, Some(px(120.)), true));

        div()
            .flex()
            .flex_col()
            .size_full()
            .bg(rgb(palette::BG))
            .text_color(rgb(palette::TEXT_PRIMARY))
            .text_sm()
            .child(header)
            .child(
                div().flex_1().overflow_hidden().child(
                    uniform_list("rows", row_count, move |range, _w, _cx| {
                        let rows = rows.clone();
                        let entity = entity.clone();
                        range
                            .map(|i| match &rows[i] {
                                Row::AppHeader {
                                    key,
                                    row_id,
                                    display,
                                    total,
                                    total_cpu,
                                    expanded,
                                    icon,
                                } => {
                                    let chevron = if *expanded { "▾" } else { "▸" };
                                    let key_clone = key.clone();
                                    let entity_clone = entity.clone();
                                    div()
                                        .id(row_id.clone())
                                        .flex()
                                        .flex_row()
                                        .w_full()
                                        .h(px(26.))
                                        .px_3()
                                        .items_center()
                                        .bg(rgb(palette::APP_ROW_BG))
                                        .hover(|s| s.bg(rgb(palette::HOVER_BG)))
                                        .cursor_pointer()
                                        .on_mouse_down(
                                            MouseButton::Left,
                                            move |_, _, app| {
                                                let key = key_clone.clone();
                                                entity_clone.update(app, |this, cx| {
                                                    if !this.expanded.remove(&key) {
                                                        this.expanded.insert(key);
                                                    }
                                                    cx.notify();
                                                });
                                            },
                                        )
                                        .child(
                                            div()
                                                .w(px(80.))
                                                .text_color(rgb(palette::TEXT_SECONDARY))
                                                .child(chevron),
                                        )
                                        .child(
                                            div()
                                                .flex_1()
                                                .flex()
                                                .flex_row()
                                                .items_center()
                                                .gap_2()
                                                .text_color(rgb(palette::TEXT_APP_NAME))
                                                .child({
                                                    let slot = div()
                                                        .w(px(16.))
                                                        .h(px(16.))
                                                        .flex_none();
                                                    match icon {
                                                        Some(icon) => slot.child(
                                                            img(icon.clone())
                                                                .w(px(16.))
                                                                .h(px(16.)),
                                                        ),
                                                        None => slot,
                                                    }
                                                })
                                                .child(display.clone()),
                                        )
                                        .child(
                                            div()
                                                .w(px(70.))
                                                .flex()
                                                .justify_end()
                                                .text_color(rgb(palette::TEXT_APP_NAME))
                                                .child(format_cpu(*total_cpu)),
                                        )
                                        .child(
                                            div()
                                                .w(px(120.))
                                                .flex()
                                                .justify_end()
                                                .text_color(rgb(palette::TEXT_APP_NAME))
                                                .child(format_memory(*total)),
                                        )
                                        .into_any_element()
                                }
                                Row::Process { pid, name, memory, cpu } => {
                                    let bg = if i % 2 == 1 { palette::BG_ALT } else { palette::BG };
                                    div()
                                        .flex()
                                        .flex_row()
                                        .w_full()
                                        .h(px(24.))
                                        .px_3()
                                        .items_center()
                                        .bg(rgb(bg))
                                        .text_color(rgb(palette::TEXT_SECONDARY))
                                        .hover(|s| s.bg(rgb(palette::HOVER_BG)))
                                        .child(
                                            div()
                                                .w(px(80.))
                                                .pl(px(24.))
                                                .child(format!("{}", pid)),
                                        )
                                        .child(
                                            div()
                                                .flex_1()
                                                .flex()
                                                .flex_row()
                                                .items_center()
                                                .gap_2()
                                                .child(
                                                    div().w(px(16.)).h(px(16.)).flex_none(),
                                                )
                                                .child(name.clone()),
                                        )
                                        .child(
                                            div()
                                                .w(px(70.))
                                                .flex()
                                                .justify_end()
                                                .child(format_cpu(*cpu)),
                                        )
                                        .child(
                                            div()
                                                .w(px(120.))
                                                .flex()
                                                .justify_end()
                                                .child(format_memory(*memory)),
                                        )
                                        .into_any_element()
                                }
                                Row::Standalone { pid, name, memory, cpu, icon } => {
                                    let bg = if i % 2 == 1 { palette::BG_ALT } else { palette::BG };
                                    div()
                                        .flex()
                                        .flex_row()
                                        .w_full()
                                        .h(px(24.))
                                        .px_3()
                                        .items_center()
                                        .bg(rgb(bg))
                                        .hover(|s| s.bg(rgb(palette::HOVER_BG)))
                                        .child(div().w(px(80.)).child(format!("{}", pid)))
                                        .child(
                                            div()
                                                .flex_1()
                                                .flex()
                                                .flex_row()
                                                .items_center()
                                                .gap_2()
                                                .child({
                                                    let slot = div()
                                                        .w(px(16.))
                                                        .h(px(16.))
                                                        .flex_none();
                                                    match icon {
                                                        Some(icon) => slot.child(
                                                            img(icon.clone())
                                                                .w(px(16.))
                                                                .h(px(16.)),
                                                        ),
                                                        None => slot,
                                                    }
                                                })
                                                .child(name.clone()),
                                        )
                                        .child(
                                            div()
                                                .w(px(70.))
                                                .flex()
                                                .justify_end()
                                                .child(format_cpu(*cpu)),
                                        )
                                        .child(
                                            div()
                                                .w(px(120.))
                                                .flex()
                                                .justify_end()
                                                .child(format_memory(*memory)),
                                        )
                                        .into_any_element()
                                }
                            })
                            .collect()
                    })
                    .size_full(),
                ),
            )
            .child(
                div()
                    .flex()
                    .flex_row()
                    .w_full()
                    .h(px(30.))
                    .px_3()
                    .items_center()
                    .gap_6()
                    .bg(rgb(palette::HEADER_BG))
                    .border_t_1()
                    .border_color(rgb(palette::BORDER))
                    .text_xs()
                    .text_color(rgb(palette::TEXT_MUTED))
                    .child(div().child(format!(
                        "Memory: {} / {}",
                        format_gb(stats.used_memory),
                        format_gb(stats.total_memory)
                    )))
                    .child(div().child(format!("CPU: {:.1}%", stats.global_cpu)))
                    .child(div().child(format!(
                        "Disk free: {} / {}",
                        format_gb(stats.free_disk),
                        format_gb(stats.total_disk)
                    ))),
            )
    }
}

fn main() {
    Application::new().run(|cx| {
        let display_size = cx
            .primary_display()
            .map(|d| d.bounds().size)
            .unwrap_or_else(|| size(px(1440.), px(900.)));
        let window_size = size(display_size.width * 0.5, display_size.height * 0.7);
        let options = WindowOptions {
            window_bounds: Some(WindowBounds::centered(window_size, cx)),
            ..Default::default()
        };
        let window = cx
            .open_window(options, |_window, cx| cx.new(|cx| ProcessMonitor::new(cx)))
            .unwrap();

        cx.bind_keys([
            KeyBinding::new("cmd-q", Quit, None),
            KeyBinding::new("cmd-h", HideApp, None),
            KeyBinding::new("cmd-m", Minimize, None),
            KeyBinding::new("ctrl-cmd-f", ToggleFullscreen, None),
        ]);

        cx.on_action(|_: &Quit, cx| cx.quit());
        cx.on_action(|_: &HideApp, cx| cx.hide());
        cx.on_action(move |_: &Minimize, cx| {
            window
                .update(cx, |_, window, _| window.minimize_window())
                .ok();
        });
        cx.on_action(move |_: &Zoom, cx| {
            window
                .update(cx, |_, window, _| window.zoom_window())
                .ok();
        });
        cx.on_action(move |_: &ToggleFullscreen, cx| {
            window
                .update(cx, |_, window, _| window.toggle_fullscreen())
                .ok();
        });

        cx.set_menus(vec![
            Menu {
                name: "Activity Monitor".into(),
                items: vec![
                    MenuItem::action("Hide Activity Monitor", HideApp),
                    MenuItem::separator(),
                    MenuItem::action("Quit Activity Monitor", Quit),
                ],
            },
            Menu {
                name: "Window".into(),
                items: vec![
                    MenuItem::action("Minimize", Minimize),
                    MenuItem::action("Zoom", Zoom),
                    MenuItem::separator(),
                    MenuItem::action("Enter Full Screen", ToggleFullscreen),
                ],
            },
        ]);

        cx.activate(true);
    });
}
