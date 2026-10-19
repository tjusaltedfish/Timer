const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
String hm(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
String dateKey(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
String taskState(String? value) =>
    {
      'ready': '可执行',
      'in_progress': '进行中',
      'waiting': '等待结果',
      'review': '待验收',
      'done': '已完成',
      'cancelled': '已取消',
    }[value] ??
    '未确认';
