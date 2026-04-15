import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/backend_config.dart';

class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  static const String storageKey = 'flowgnimag_tasks';
  static const String cloudTokenKey = 'flowgnimag_cloud_token';

  final TextEditingController taskController = TextEditingController();
  final TextEditingController searchController = TextEditingController();

  List<Map<String, dynamic>> tasks = [];
  bool isLoading = true;
  String searchText = '';
  String cloudToken = '';

  String get apiBaseUrl {
    return BackendConfig.apiBaseUrl;
  }

  bool get isCloudConnected => cloudToken.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    loadTasks();
  }

  Future<void> loadTasks() async {
    final prefs = await SharedPreferences.getInstance();
    cloudToken = prefs.getString(cloudTokenKey) ?? '';

    if (isCloudConnected) {
      try {
        final response = await http.get(
          Uri.parse('$apiBaseUrl/tasks'),
          headers: {"Authorization": "Bearer $cloudToken"},
        );
        final data = response.body.isNotEmpty
            ? jsonDecode(response.body) as Map<String, dynamic>
            : <String, dynamic>{};
        if (response.statusCode >= 200 && response.statusCode < 300) {
          tasks = (data["tasks"] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map((item) {
                return {
                  "id": (item["id"] ?? "").toString(),
                  "title": (item["title"] ?? "").toString(),
                  "done": item["done"] == true,
                  "priority": (item["priority"] ?? "Medium").toString(),
                  "createdAt":
                      (item["createdAt"] ?? DateTime.now().toIso8601String())
                          .toString(),
                };
              })
              .toList();
          await saveTasks();
        }
      } catch (_) {}
    }

    final saved = prefs.getString(storageKey);

    if (tasks.isEmpty && saved != null && saved.isNotEmpty) {
      final List decoded = jsonDecode(saved);
      tasks = decoded.map<Map<String, dynamic>>((item) {
        return {
          "title": item["title"],
          "done": item["done"] ?? false,
          "priority": item["priority"] ?? "Medium",
          "createdAt": item["createdAt"] ?? "",
        };
      }).toList();
    }

    if (!mounted) return;

    setState(() => isLoading = false);
  }

  Future<void> saveTasks() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, jsonEncode(tasks));
  }

  void showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> addTask(String priority) async {
    final text = taskController.text.trim();

    if (text.isEmpty) {
      showSnack("Enter task first");
      return;
    }

    if (isCloudConnected) {
      try {
        final response = await http.post(
          Uri.parse('$apiBaseUrl/tasks'),
          headers: {
            "Authorization": "Bearer $cloudToken",
            "Content-Type": "application/json",
          },
          body: jsonEncode({
            "title": text,
            "priority": priority,
            "done": false,
          }),
        );
        final data = response.body.isNotEmpty
            ? jsonDecode(response.body) as Map<String, dynamic>
            : <String, dynamic>{};
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final task = (data["task"] as Map<String, dynamic>? ?? {});
          setState(() {
            tasks.insert(0, {
              "id": (task["id"] ?? "").toString(),
              "title": (task["title"] ?? text).toString(),
              "done": task["done"] == true,
              "priority": (task["priority"] ?? priority).toString(),
              "createdAt":
                  (task["createdAt"] ?? DateTime.now().toIso8601String())
                      .toString(),
            });
          });
          taskController.clear();
          await saveTasks();
          showSnack("Task added");
          return;
        }
      } catch (_) {}
      showSnack("Could not add cloud task.");
      return;
    }

    setState(() {
      tasks.insert(0, {
        "title": text,
        "done": false,
        "priority": priority,
        "createdAt": DateTime.now().toIso8601String(),
      });
    });
    taskController.clear();
    await saveTasks();
    showSnack("Task added");
  }

  Future<void> toggleTask(int index) async {
    if (isCloudConnected && (tasks[index]["id"] ?? "").toString().isNotEmpty) {
      final nextDone = !(tasks[index]["done"] == true);
      try {
        final response = await http.patch(
          Uri.parse('$apiBaseUrl/tasks/${tasks[index]["id"]}'),
          headers: {
            "Authorization": "Bearer $cloudToken",
            "Content-Type": "application/json",
          },
          body: jsonEncode({"done": nextDone}),
        );
        if (response.statusCode >= 200 && response.statusCode < 300) {
          setState(() {
            tasks[index]["done"] = nextDone;
          });
          await saveTasks();
          return;
        }
      } catch (_) {}
      showSnack("Could not update cloud task.");
      return;
    }

    setState(() {
      tasks[index]["done"] = !tasks[index]["done"];
    });

    await saveTasks();
  }

  Future<void> deleteTask(int index) async {
    final deleted = Map<String, dynamic>.from(tasks[index]);

    if (isCloudConnected && (deleted["id"] ?? "").toString().isNotEmpty) {
      try {
        final response = await http.delete(
          Uri.parse('$apiBaseUrl/tasks/${deleted["id"]}'),
          headers: {"Authorization": "Bearer $cloudToken"},
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          showSnack("Could not delete cloud task.");
          return;
        }
      } catch (_) {
        showSnack("Could not delete cloud task.");
        return;
      }
    }

    setState(() {
      tasks.removeAt(index);
    });

    await saveTasks();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text("Task deleted"),
        action: SnackBarAction(
          label: "Undo",
          onPressed: () async {
            setState(() {
              tasks.insert(index, deleted);
            });
            await saveTasks();
          },
        ),
      ),
    );
  }

  Future<void> clearAllTasks() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Clear All Tasks"),
        content: const Text("Delete all tasks?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    if (isCloudConnected) {
      final ids = tasks.map((t) => (t["id"] ?? "").toString()).toList();
      for (final id in ids) {
        if (id.isEmpty) continue;
        try {
          await http.delete(
            Uri.parse('$apiBaseUrl/tasks/$id'),
            headers: {"Authorization": "Bearer $cloudToken"},
          );
        } catch (_) {}
      }
    }

    setState(() => tasks.clear());
    await saveTasks();
    showSnack("All tasks cleared");
  }

  void openAddTaskDialog() {
    String selectedPriority = "Medium";

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Add Task"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: taskController,
              decoration: const InputDecoration(hintText: "Enter task..."),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: selectedPriority,
              items: [
                "Low",
                "Medium",
                "High",
              ].map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
              onChanged: (val) {
                selectedPriority = val!;
              },
              decoration: const InputDecoration(labelText: "Priority"),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              taskController.clear();
              Navigator.pop(context);
            },
            child: const Text("Cancel"),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              await addTask(selectedPriority);
            },
            child: const Text("Add"),
          ),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> get filteredTasks {
    if (searchText.isEmpty) return tasks;

    return tasks.where((task) {
      return task["title"].toString().toLowerCase().contains(
        searchText.toLowerCase(),
      );
    }).toList();
  }

  Color getPriorityColor(String priority) {
    switch (priority) {
      case "High":
        return Colors.redAccent;
      case "Medium":
        return Colors.orangeAccent;
      default:
        return Colors.greenAccent;
    }
  }

  Widget buildTaskCard(Map<String, dynamic> task, int index) {
    final isDone = task["done"] == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          Checkbox(value: isDone, onChanged: (_) => toggleTask(index)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task["title"],
                  style: TextStyle(
                    fontSize: 15,
                    decoration: isDone ? TextDecoration.lineThrough : null,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  task["priority"],
                  style: TextStyle(
                    fontSize: 12,
                    color: getPriorityColor(task["priority"]),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => deleteTask(index),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleTasks = filteredTasks;

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: openAddTaskDialog,
        label: const Text("Add Task"),
        icon: const Icon(Icons.add),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          "Tasks (${tasks.length})",
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: tasks.isEmpty ? null : clearAllTasks,
                        icon: const Icon(Icons.delete_sweep),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: searchController,
                    onChanged: (val) {
                      setState(() => searchText = val);
                    },
                    decoration: InputDecoration(
                      hintText: "Search tasks...",
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: visibleTasks.isEmpty
                      ? const Center(child: Text("No tasks found"))
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: visibleTasks.length,
                          itemBuilder: (_, i) =>
                              buildTaskCard(visibleTasks[i], i),
                        ),
                ),
              ],
            ),
    );
  }
}
