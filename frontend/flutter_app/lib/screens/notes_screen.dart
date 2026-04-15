import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  static const String storageKey = 'flowgnimag_notes';
  static const String cloudTokenKey = 'flowgnimag_cloud_token';

  final TextEditingController noteController = TextEditingController();
  final TextEditingController searchController = TextEditingController();

  List<Map<String, dynamic>> notes = [];
  bool isLoading = true;
  String searchText = '';
  String cloudToken = '';

  String get apiBaseUrl {
    const fromEnv = String.fromEnvironment('API_BASE_URL');
    if (fromEnv.isNotEmpty) return fromEnv;
    if (kIsWeb) return 'http://localhost:5000';
    return 'http://10.0.2.2:5000';
  }

  bool get isCloudConnected => cloudToken.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    loadNotes();
  }

  Future<void> loadNotes() async {
    final prefs = await SharedPreferences.getInstance();
    cloudToken = prefs.getString(cloudTokenKey) ?? '';

    if (isCloudConnected) {
      try {
        final response = await http.get(
          Uri.parse('$apiBaseUrl/notes'),
          headers: {"Authorization": "Bearer $cloudToken"},
        );
        final data = response.body.isNotEmpty
            ? jsonDecode(response.body) as Map<String, dynamic>
            : <String, dynamic>{};
        if (response.statusCode >= 200 && response.statusCode < 300) {
          notes = (data["notes"] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map((item) {
                return {
                  "id": (item["id"] ?? "").toString(),
                  "text": item["text"]?.toString() ?? "",
                  "createdAt": item["createdAt"]?.toString() ?? "",
                  "updatedAt": item["updatedAt"]?.toString() ?? "",
                };
              })
              .toList();
          await saveNotes();
        }
      } catch (_) {}
    }

    final saved = prefs.getString(storageKey);

    if (notes.isEmpty && saved != null && saved.isNotEmpty) {
      try {
        final List<dynamic> decoded = jsonDecode(saved);
        notes = decoded.map<Map<String, dynamic>>((item) {
          return {
            "text": item["text"]?.toString() ?? "",
            "createdAt": item["createdAt"]?.toString() ?? "",
          };
        }).toList();
      } catch (_) {
        notes = [];
      }
    }

    if (!mounted) return;

    setState(() {
      isLoading = false;
    });
  }

  Future<void> saveNotes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, jsonEncode(notes));
  }

  void showSnackBar(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> addNote() async {
    final text = noteController.text.trim();

    if (text.isEmpty) {
      showSnackBar("Please write a note first.");
      return;
    }

    if (isCloudConnected) {
      try {
        final response = await http.post(
          Uri.parse('$apiBaseUrl/notes'),
          headers: {
            "Authorization": "Bearer $cloudToken",
            "Content-Type": "application/json",
          },
          body: jsonEncode({"text": text}),
        );
        final data = response.body.isNotEmpty
            ? jsonDecode(response.body) as Map<String, dynamic>
            : <String, dynamic>{};
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final note = (data["note"] as Map<String, dynamic>? ?? {});
          setState(() {
            notes.insert(0, {
              "id": (note["id"] ?? "").toString(),
              "text": (note["text"] ?? text).toString(),
              "createdAt":
                  (note["createdAt"] ?? DateTime.now().toIso8601String())
                      .toString(),
              "updatedAt": (note["updatedAt"] ?? "").toString(),
            });
          });
          noteController.clear();
          await saveNotes();
          showSnackBar("Note added successfully.");
          return;
        }
      } catch (_) {}
      showSnackBar("Could not save cloud note.");
      return;
    }

    setState(() {
      notes.insert(0, {
        "text": text,
        "createdAt": DateTime.now().toIso8601String(),
      });
    });
    noteController.clear();
    await saveNotes();
    showSnackBar("Note added successfully.");
  }

  Future<void> updateNote(int index) async {
    final text = noteController.text.trim();

    if (text.isEmpty) {
      showSnackBar("Note cannot be empty.");
      return;
    }

    if (isCloudConnected && (notes[index]["id"] ?? "").toString().isNotEmpty) {
      try {
        final response = await http.patch(
          Uri.parse('$apiBaseUrl/notes/${notes[index]["id"]}'),
          headers: {
            "Authorization": "Bearer $cloudToken",
            "Content-Type": "application/json",
          },
          body: jsonEncode({"text": text}),
        );
        if (response.statusCode >= 200 && response.statusCode < 300) {
          setState(() {
            notes[index]["text"] = text;
          });
          noteController.clear();
          await saveNotes();
          showSnackBar("Note updated successfully.");
          return;
        }
      } catch (_) {}
      showSnackBar("Could not update cloud note.");
      return;
    }

    setState(() {
      notes[index]["text"] = text;
    });
    noteController.clear();
    await saveNotes();
    showSnackBar("Note updated successfully.");
  }

  Future<void> deleteNote(int index) async {
    final deletedNote = Map<String, dynamic>.from(notes[index]);

    if (isCloudConnected && (deletedNote["id"] ?? "").toString().isNotEmpty) {
      try {
        final response = await http.delete(
          Uri.parse('$apiBaseUrl/notes/${deletedNote["id"]}'),
          headers: {"Authorization": "Bearer $cloudToken"},
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          showSnackBar("Could not delete cloud note.");
          return;
        }
      } catch (_) {
        showSnackBar("Could not delete cloud note.");
        return;
      }
    }

    setState(() {
      notes.removeAt(index);
    });

    await saveNotes();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text("Note deleted"),
        action: SnackBarAction(
          label: "Undo",
          onPressed: () async {
            setState(() {
              notes.insert(index, deletedNote);
            });
            await saveNotes();
          },
        ),
      ),
    );
  }

  Future<void> clearAllNotes() async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Clear All Notes"),
          content: const Text("Are you sure you want to delete all notes?"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Cancel"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text("Delete All"),
            ),
          ],
        );
      },
    );

    if (shouldDelete != true) return;

    if (isCloudConnected) {
      final ids = notes.map((n) => (n["id"] ?? "").toString()).toList();
      for (final id in ids) {
        if (id.isEmpty) continue;
        try {
          await http.delete(
            Uri.parse('$apiBaseUrl/notes/$id'),
            headers: {"Authorization": "Bearer $cloudToken"},
          );
        } catch (_) {}
      }
    }

    setState(() {
      notes.clear();
    });

    await saveNotes();
    showSnackBar("All notes cleared.");
  }

  void openAddNoteDialog() {
    noteController.clear();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Add Note"),
          content: TextField(
            controller: noteController,
            maxLines: 5,
            decoration: const InputDecoration(
              hintText: "Write your note here...",
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                noteController.clear();
                Navigator.pop(context);
              },
              child: const Text("Cancel"),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(context);
                await addNote();
              },
              child: const Text("Save"),
            ),
          ],
        );
      },
    );
  }

  void openEditNoteDialog(int index) {
    noteController.text = notes[index]["text"] ?? "";

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Edit Note"),
          content: TextField(
            controller: noteController,
            maxLines: 5,
            decoration: const InputDecoration(hintText: "Update your note..."),
          ),
          actions: [
            TextButton(
              onPressed: () {
                noteController.clear();
                Navigator.pop(context);
              },
              child: const Text("Cancel"),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(context);
                await updateNote(index);
              },
              child: const Text("Update"),
            ),
          ],
        );
      },
    );
  }

  String formatDateTime(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return "";

    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final year = dt.year.toString();

    int hour = dt.hour;
    final minute = dt.minute.toString().padLeft(2, '0');
    final amPm = hour >= 12 ? "PM" : "AM";

    hour = hour % 12;
    if (hour == 0) hour = 12;

    return "$day/$month/$year • $hour:$minute $amPm";
  }

  List<Map<String, dynamic>> get filteredNotes {
    if (searchText.trim().isEmpty) return notes;

    return notes.where((note) {
      final text = (note["text"] ?? "").toString().toLowerCase();
      return text.contains(searchText.toLowerCase());
    }).toList();
  }

  Widget buildTopCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "My Notes",
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            "${notes.length} note${notes.length == 1 ? '' : 's'} saved",
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget buildEmptyState() {
    final isSearching = searchText.trim().isNotEmpty;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.note_alt_outlined,
              size: 64,
              color: Colors.white.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 14),
            Text(
              isSearching ? "No matching notes found" : "No notes yet",
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              isSearching
                  ? "Try another search word."
                  : "Tap 'Add Note' to create your first note.",
              style: const TextStyle(fontSize: 14, color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget buildNoteCard(Map<String, dynamic> note, int originalIndex) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            note["text"] ?? "",
            style: const TextStyle(fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  formatDateTime(note["createdAt"] ?? ""),
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ),
              IconButton(
                onPressed: () => openEditNoteDialog(originalIndex),
                icon: const Icon(Icons.edit_outlined),
                tooltip: "Edit",
              ),
              IconButton(
                onPressed: () => deleteNote(originalIndex),
                icon: const Icon(Icons.delete_outline),
                tooltip: "Delete",
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    noteController.dispose();
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visibleNotes = filteredNotes;

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: openAddNoteDialog,
        icon: const Icon(Icons.add),
        label: const Text("Add Note"),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    children: [
                      Expanded(child: buildTopCard()),
                      const SizedBox(width: 10),
                      IconButton(
                        onPressed: notes.isEmpty ? null : clearAllNotes,
                        icon: const Icon(Icons.delete_sweep_outlined),
                        tooltip: "Clear All",
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    controller: searchController,
                    onChanged: (value) {
                      setState(() {
                        searchText = value;
                      });
                    },
                    decoration: InputDecoration(
                      hintText: "Search notes...",
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: visibleNotes.isEmpty
                      ? buildEmptyState()
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
                          itemCount: visibleNotes.length,
                          itemBuilder: (context, index) {
                            final note = visibleNotes[index];
                            final originalIndex = notes.indexOf(note);

                            return buildNoteCard(note, originalIndex);
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
