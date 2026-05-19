use std::collections::{HashMap, HashSet};
use std::ffi::c_void;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use gpui::{
    div, prelude::*, px, rgb, size, uniform_list, Application, Context, MouseButton, SharedString,
    Window, WindowBounds, WindowOptions,
};
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

fn app_for_exe(exe: &Path) -> Option<String> {
    let s = exe.to_str()?;
    let idx = s.find(".app/")?;
    let prefix = &s[..idx];
    let name_start = prefix.rfind('/').map(|p| p + 1).unwrap_or(0);
    Some(s[name_start..idx].to_string())
}

#[derive(Clone)]
struct ProcessInfo {
    pid: u32,
    name: SharedString,
    memory_bytes: u64,
}

struct AppGroup {
    key: SharedString,
    display_name: SharedString,
    is_app_bundle: bool,
    total_memory: u64,
    processes: Vec<ProcessInfo>,
}

struct ProcessMonitor {
    system: System,
    groups: Arc<Vec<AppGroup>>,
    expanded: HashSet<SharedString>,
}

fn build_groups(sys: &System) -> Vec<AppGroup> {
    let mut by_app: HashMap<String, (bool, Vec<ProcessInfo>)> = HashMap::new();

    for (pid, p) in sys.processes() {
        let pid_u32 = pid.as_u32();
        let memory = phys_footprint(pid_u32).unwrap_or_else(|| p.memory());
        let proc_name = p.name().to_string_lossy().into_owned();
        let pi = ProcessInfo {
            pid: pid_u32,
            name: SharedString::from(proc_name.clone()),
            memory_bytes: memory,
        };
        let (key, is_app) = match p.exe().and_then(app_for_exe) {
            Some(app) => (app, true),
            None => (proc_name, false),
        };
        let entry = by_app.entry(key).or_insert((is_app, Vec::new()));
        entry.0 = entry.0 || is_app;
        entry.1.push(pi);
    }

    let mut groups: Vec<AppGroup> = by_app
        .into_iter()
        .map(|(name, (is_app, mut processes))| {
            processes.sort_by(|a, b| b.memory_bytes.cmp(&a.memory_bytes));
            let total: u64 = processes.iter().map(|p| p.memory_bytes).sum();
            let shared = SharedString::from(name);
            AppGroup {
                key: shared.clone(),
                display_name: shared,
                is_app_bundle: is_app,
                total_memory: total,
                processes,
            }
        })
        .collect();

    groups.sort_by(|a, b| b.total_memory.cmp(&a.total_memory));
    groups
}

impl ProcessMonitor {
    fn new(cx: &mut Context<Self>) -> Self {
        let mut system = System::new_all();
        system.refresh_processes(ProcessesToUpdate::All, true);
        let groups = Arc::new(build_groups(&system));

        cx.spawn(async move |this, cx| loop {
            cx.background_executor()
                .timer(Duration::from_secs(2))
                .await;
            let r = this.update(cx, |this, cx| {
                this.system
                    .refresh_processes(ProcessesToUpdate::All, true);
                this.groups = Arc::new(build_groups(&this.system));
                cx.notify();
            });
            if r.is_err() {
                break;
            }
        })
        .detach();

        Self {
            system,
            groups,
            expanded: HashSet::new(),
        }
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

enum Row {
    AppHeader {
        key: SharedString,
        display: SharedString,
        total: u64,
        count: usize,
        expanded: bool,
    },
    Process {
        pid: u32,
        name: SharedString,
        memory: u64,
    },
    Standalone {
        pid: u32,
        name: SharedString,
        memory: u64,
    },
}

fn build_rows(groups: &[AppGroup], expanded: &HashSet<SharedString>) -> Vec<Row> {
    let mut out = Vec::new();
    for g in groups {
        if g.processes.len() == 1 {
            let p = &g.processes[0];
            out.push(Row::Standalone {
                pid: p.pid,
                name: if g.is_app_bundle {
                    g.display_name.clone()
                } else {
                    p.name.clone()
                },
                memory: g.total_memory,
            });
        } else {
            let is_expanded = expanded.contains(&g.key);
            out.push(Row::AppHeader {
                key: g.key.clone(),
                display: g.display_name.clone(),
                total: g.total_memory,
                count: g.processes.len(),
                expanded: is_expanded,
            });
            if is_expanded {
                for p in &g.processes {
                    out.push(Row::Process {
                        pid: p.pid,
                        name: p.name.clone(),
                        memory: p.memory_bytes,
                    });
                }
            }
        }
    }
    out
}

impl Render for ProcessMonitor {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let rows = Arc::new(build_rows(&self.groups, &self.expanded));
        let row_count = rows.len();
        let entity = cx.entity();

        let header = div()
            .flex()
            .flex_row()
            .w_full()
            .h(px(28.))
            .bg(rgb(0x2a2a2a))
            .text_color(rgb(0xcccccc))
            .border_b_1()
            .border_color(rgb(0x3a3a3a))
            .px_3()
            .items_center()
            .child(div().w(px(80.)).child("PID"))
            .child(div().flex_1().child("Name"))
            .child(div().w(px(120.)).flex().justify_end().child("Memory"));

        div()
            .flex()
            .flex_col()
            .size_full()
            .bg(rgb(0x1e1e1e))
            .text_color(rgb(0xeeeeee))
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
                                    display,
                                    total,
                                    count,
                                    expanded,
                                } => {
                                    let chevron = if *expanded { "v" } else { ">" };
                                    let key_clone = key.clone();
                                    let entity_clone = entity.clone();
                                    let id_str: SharedString =
                                        format!("group-{}", key).into();
                                    div()
                                        .id(id_str)
                                        .flex()
                                        .flex_row()
                                        .w_full()
                                        .h(px(24.))
                                        .px_3()
                                        .items_center()
                                        .bg(rgb(0x252525))
                                        .hover(|s| s.bg(rgb(0x2f2f2f)))
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
                                                .child(format!("{} {}", chevron, count)),
                                        )
                                        .child(
                                            div()
                                                .flex_1()
                                                .text_color(rgb(0xffffff))
                                                .child(display.clone()),
                                        )
                                        .child(
                                            div()
                                                .w(px(120.))
                                                .flex()
                                                .justify_end()
                                                .text_color(rgb(0xffffff))
                                                .child(format_memory(*total)),
                                        )
                                        .into_any_element()
                                }
                                Row::Process { pid, name, memory } => div()
                                    .flex()
                                    .flex_row()
                                    .w_full()
                                    .h(px(22.))
                                    .pl(px(36.))
                                    .pr_3()
                                    .items_center()
                                    .text_color(rgb(0xbbbbbb))
                                    .hover(|s| s.bg(rgb(0x2a2a2a)))
                                    .child(div().w(px(60.)).child(format!("{}", pid)))
                                    .child(div().flex_1().child(name.clone()))
                                    .child(
                                        div()
                                            .w(px(120.))
                                            .flex()
                                            .justify_end()
                                            .child(format_memory(*memory)),
                                    )
                                    .into_any_element(),
                                Row::Standalone { pid, name, memory } => div()
                                    .flex()
                                    .flex_row()
                                    .w_full()
                                    .h(px(22.))
                                    .px_3()
                                    .items_center()
                                    .hover(|s| s.bg(rgb(0x2a2a2a)))
                                    .child(div().w(px(80.)).child(format!("{}", pid)))
                                    .child(div().flex_1().child(name.clone()))
                                    .child(
                                        div()
                                            .w(px(120.))
                                            .flex()
                                            .justify_end()
                                            .child(format_memory(*memory)),
                                    )
                                    .into_any_element(),
                            })
                            .collect()
                    })
                    .size_full(),
                ),
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
        cx.open_window(options, |_window, cx| {
            cx.new(|cx| ProcessMonitor::new(cx))
        })
        .unwrap();
        cx.activate(true);
    });
}
