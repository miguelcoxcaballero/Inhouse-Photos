using System;
using System.Globalization;
using System.IO;
using System.Text;

namespace InhousePhotos {
  // This file holds preferences and scheduling metadata only. The caller must
  // check server health, validate the backup destination, and perform Backup().
  // All timestamps are ISO 8601 UTC; no server credentials or exception text
  // are persisted here.
  public sealed class BackupSchedule {
    public int Format { get; set; }
    public bool Enabled { get; set; }
    public string EnabledUtc { get; set; }
    public string NextDueUtc { get; set; }
    public string LastAttemptUtc { get; set; }
    public string LastSuccessUtc { get; set; }
    public int ConsecutiveFailures { get; set; }
    public string LastErrorCode { get; set; }
    public string LastError { get; set; }
  }

  public static partial class Backend {
    static readonly object BackupScheduleLock = new object();
    static string BackupSchedulePath { get { return Path.Combine(SettingsDir,"backup-schedule.json"); } }

    static BackupSchedule DisabledBackupSchedule() {
      return new BackupSchedule { Format=1,Enabled=false,ConsecutiveFailures=0,
        LastErrorCode="",LastError="" };
    }

    static string UtcText(DateTime value) {
      return value.ToUniversalTime().ToString("o",CultureInfo.InvariantCulture);
    }

    static bool TryUtc(string value,out DateTime parsed) {
      parsed=default(DateTime);
      return !String.IsNullOrWhiteSpace(value) &&
        DateTime.TryParseExact(value,"o",CultureInfo.InvariantCulture,
          DateTimeStyles.RoundtripKind,out parsed) && parsed.Kind==DateTimeKind.Utc;
    }

    static bool ValidOptionalUtc(string value) {
      DateTime ignored;
      return String.IsNullOrEmpty(value)||TryUtc(value,out ignored);
    }

    static void SetSafeScheduleError(BackupSchedule schedule,string code) {
      switch(code) {
        case "destination":
          schedule.LastErrorCode=code;
          schedule.LastError="No se pudo usar el disco de copia. Comprueba que esté conectado y tenga espacio.";
          break;
        case "server":
          schedule.LastErrorCode=code;
          schedule.LastError="El servidor no estaba disponible para completar la copia.";
          break;
        case "cancelled":
          schedule.LastErrorCode=code;
          schedule.LastError="La copia automática se interrumpió antes de terminar.";
          break;
        case "":
          schedule.LastErrorCode="";schedule.LastError="";
          break;
        default:
          schedule.LastErrorCode="unknown";
          schedule.LastError="La copia automática no se completó. Comprueba el servidor y el disco de destino.";
          break;
      }
    }

    static DateTime NextWeeklyBackupUtc(DateTime nowUtc) {
      // One predictable weekly slot, also valid across local DST changes.
      // A missed slot remains due on the next app launch.
      var sunday=new DateTime(nowUtc.Year,nowUtc.Month,nowUtc.Day,3,0,0,DateTimeKind.Utc);
      sunday=sunday.AddDays((7-(int)nowUtc.DayOfWeek)%7);
      return sunday<=nowUtc?sunday.AddDays(7):sunday;
    }

    static BackupSchedule ReadBackupScheduleCore() {
      try {
        if(!File.Exists(BackupSchedulePath))return DisabledBackupSchedule();
        var value=Json.Deserialize<BackupSchedule>(File.ReadAllText(BackupSchedulePath));
        DateTime due;
        if(value==null||value.Format!=1||value.ConsecutiveFailures<0||
            value.ConsecutiveFailures>100000||!ValidOptionalUtc(value.EnabledUtc)||
            !ValidOptionalUtc(value.LastAttemptUtc)||!ValidOptionalUtc(value.LastSuccessUtc)||
            (value.Enabled&&!TryUtc(value.NextDueUtc,out due))||
            (!value.Enabled&&!ValidOptionalUtc(value.NextDueUtc)))
          return DisabledBackupSchedule();
        // Do not surface arbitrary persisted text as an error message. Even a
        // modified or old file cannot inject a path or token into the UI.
        SetSafeScheduleError(value,value.LastErrorCode??"");
        // Existing metadata may remain after opting out, but it never enables
        // work without the explicit Enabled flag and a valid due timestamp.
        return value;
      } catch(IOException) { return DisabledBackupSchedule(); }
        catch(UnauthorizedAccessException) { return DisabledBackupSchedule(); }
        catch(ArgumentException) { return DisabledBackupSchedule(); }
        catch(InvalidOperationException) { return DisabledBackupSchedule(); }
    }

    static void SaveBackupScheduleCore(BackupSchedule schedule) {
      PrivateDirectory(SettingsDir);
      var path=BackupSchedulePath;
      var temp=path+"."+RandomHex(8)+".new";
      try {
        File.WriteAllText(temp,Json.Serialize(schedule),new UTF8Encoding(false));
        if(File.Exists(path))File.Replace(temp,path,null);else File.Move(temp,path);
      } finally { if(File.Exists(temp))File.Delete(temp); }
    }

    public static BackupSchedule ReadBackupSchedule() {
      lock(BackupScheduleLock)return ReadBackupScheduleCore();
    }

    // Enabling never starts a backup immediately. It schedules the next Sunday
    // at 03:00 UTC. Disabling preserves history but clears pending work.
    public static BackupSchedule SetBackupScheduleEnabled(bool enabled) {
      lock(BackupScheduleLock) {
        var schedule=ReadBackupScheduleCore();
        if(enabled&&!schedule.Enabled) {
          var now=DateTime.UtcNow;
          schedule.Enabled=true;
          schedule.EnabledUtc=UtcText(now);
          schedule.NextDueUtc=UtcText(NextWeeklyBackupUtc(now));
          schedule.ConsecutiveFailures=0;
          schedule.LastErrorCode="";schedule.LastError="";
        } else if(!enabled&&schedule.Enabled) {
          schedule.Enabled=false; schedule.NextDueUtc=null;
        } else return schedule;
        SaveBackupScheduleCore(schedule);
        return schedule;
      }
    }

    public static bool IsBackupDue(BackupSchedule schedule,DateTime nowUtc) {
      if(nowUtc.Kind!=DateTimeKind.Utc)
        throw new ArgumentException("La hora de comprobación debe estar en UTC.","nowUtc");
      DateTime due;
      return schedule!=null&&schedule.Enabled&&TryUtc(schedule.NextDueUtc,out due)&&due<=nowUtc;
    }

    public static bool IsBackupDue(DateTime nowUtc) {
      return IsBackupDue(ReadBackupSchedule(),nowUtc);
    }

    public static bool IsBackupDue() {
      return IsBackupDue(DateTime.UtcNow);
    }

    // Call immediately before dispatching a scheduled Backup(). This records
    // a recovery delay in case the app exits mid-copy, avoiding an immediate
    // restart loop. A successful/failed result supersedes it.
    public static BackupSchedule RecordScheduledBackupStart() {
      lock(BackupScheduleLock) {
        var schedule=ReadBackupScheduleCore();
        if(!schedule.Enabled)throw new InvalidOperationException("La copia semanal no está activada.");
        var now=DateTime.UtcNow;
        if(!IsBackupDue(schedule,now))
          throw new InvalidOperationException("La siguiente copia semanal aún no corresponde.");
        schedule.LastAttemptUtc=UtcText(now);
        schedule.NextDueUtc=UtcText(now.AddHours(24));
        SaveBackupScheduleCore(schedule);
        return schedule;
      }
    }

    // A successful manual copy satisfies the upcoming weekly run. Do not
    // launch an identical, potentially large copy minutes later.
    public static BackupSchedule RecordManualBackupSuccessForSchedule() {
      lock(BackupScheduleLock) {
        var schedule=ReadBackupScheduleCore();
        if(!schedule.Enabled)return schedule;
        var now=DateTime.UtcNow;
        // A manual copy restarts the seven-day interval. Skipping the next
        // Sunday could otherwise leave almost two weeks without a copy.
        var next=now.AddDays(7);
        schedule.LastSuccessUtc=UtcText(now);
        schedule.ConsecutiveFailures=0;
        schedule.LastErrorCode="";schedule.LastError="";
        schedule.NextDueUtc=UtcText(next);
        SaveBackupScheduleCore(schedule);
        return schedule;
      }
    }

    // errorCode is intentionally restricted to a small whitelist. Never pass
    // through exception messages: they may contain paths, tokens or passwords.
    // Accepted values: destination, server, cancelled; all others are generic.
    public static BackupSchedule RecordScheduledBackupResult(bool success,string errorCode) {
      lock(BackupScheduleLock) {
        var schedule=ReadBackupScheduleCore();
        var now=DateTime.UtcNow;
        schedule.LastAttemptUtc=UtcText(now);
        if(success) {
          schedule.LastSuccessUtc=UtcText(now);
          schedule.ConsecutiveFailures=0;
          schedule.LastErrorCode="";schedule.LastError="";
          schedule.NextDueUtc=schedule.Enabled?UtcText(NextWeeklyBackupUtc(now)):null;
        } else {
          schedule.ConsecutiveFailures=Math.Min(100000,schedule.ConsecutiveFailures+1);
          SetSafeScheduleError(schedule,(errorCode??"").Trim().ToLowerInvariant());
          // 15 minutes, 1 hour, 6 hours, then at most daily. Only one retry
          // is due at a time; a failed copy is never recorded as successful.
          var retryMinutes=schedule.ConsecutiveFailures==1?15:
            schedule.ConsecutiveFailures==2?60:schedule.ConsecutiveFailures==3?360:1440;
          schedule.NextDueUtc=schedule.Enabled?UtcText(now.AddMinutes(retryMinutes)):null;
        }
        SaveBackupScheduleCore(schedule);
        return schedule;
      }
    }
  }
}
