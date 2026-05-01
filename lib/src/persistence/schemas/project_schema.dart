import 'package:sqlite3/sqlite3.dart';

/// wenz_projects / wenz_project_modules / wenz_project_skills / wenz_project_issues 表 schema
class ProjectSchema {
  static void create(Database db) {
    // 项目表
    db.execute('''
      CREATE TABLE IF NOT EXISTS wenz_projects (
        uuid         TEXT PRIMARY KEY,
        user_id      INTEGER,
        space_id     TEXT,
        title        TEXT NOT NULL,
        description  TEXT,
        work_path    TEXT,
        git_url      TEXT,
        deleted      INTEGER DEFAULT 0,
        delete_by    TEXT,
        delete_time  INTEGER,
        create_by    TEXT,
        create_time  INTEGER NOT NULL,
        update_by    TEXT,
        update_time  INTEGER NOT NULL
      );
    ''');

    // 项目模块表
    db.execute('''
      CREATE TABLE IF NOT EXISTS wenz_project_modules (
        uuid         TEXT PRIMARY KEY,
        project_uuid TEXT NOT NULL,
        title        TEXT NOT NULL,
        description  TEXT,
        note_uuid    TEXT,
        sort_order   INTEGER DEFAULT 0,
        deleted      INTEGER DEFAULT 0,
        delete_by    TEXT,
        delete_time  INTEGER,
        create_by    TEXT,
        create_time  INTEGER NOT NULL,
        update_by    TEXT,
        update_time  INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_project_modules_project
        ON wenz_project_modules(project_uuid);
    ''');

    // 项目技能表
    db.execute('''
      CREATE TABLE IF NOT EXISTS wenz_project_skills (
        uuid          TEXT PRIMARY KEY,
        project_uuid  TEXT NOT NULL,
        title         TEXT NOT NULL,
        description   TEXT,
        skill_type    TEXT DEFAULT 'mcp',
        note_uuid     TEXT,
        document_uuid TEXT,
        mcp_config    TEXT,
        file_config   TEXT,
        sort_order    INTEGER DEFAULT 0,
        deleted       INTEGER DEFAULT 0,
        delete_by     TEXT,
        delete_time   INTEGER,
        create_by     TEXT,
        create_time   INTEGER NOT NULL,
        update_by     TEXT,
        update_time   INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_project_skills_project
        ON wenz_project_skills(project_uuid);
    ''');

    // 项目工单表
    db.execute('''
      CREATE TABLE IF NOT EXISTS wenz_project_issues (
        uuid         TEXT PRIMARY KEY,
        project_uuid TEXT NOT NULL,
        title        TEXT NOT NULL,
        description  TEXT,
        status       TEXT DEFAULT 'open',
        priority     TEXT DEFAULT 'medium',
        assignee     TEXT,
        close_time   INTEGER,
        deleted      INTEGER DEFAULT 0,
        delete_by    TEXT,
        delete_time  INTEGER,
        create_by    TEXT,
        create_time  INTEGER NOT NULL,
        update_by    TEXT,
        update_time  INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_project_issues_project
        ON wenz_project_issues(project_uuid);
    ''');
  }
}
